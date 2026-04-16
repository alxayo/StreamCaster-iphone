import Foundation
import AVFoundation
import CoreMedia
import Combine
import CoreGraphics
import UIKit
import VideoToolbox

// Only import SRTHaishinKit if it's available. The SRTHaishinKit module
// lives in the same HaishinKit Swift package but requires the `libsrt`
// binary framework, which may not be resolved on all build configurations.
#if canImport(HaishinKit)
import HaishinKit
#endif

#if canImport(SRTHaishinKit)
import SRTHaishinKit
#endif

// MARK: - SRTEncoderBridge
/// SRT (Secure Reliable Transport) encoder bridge.
///
/// This bridge connects to SRT servers using HaishinKit's `SRTHaishinKit`
/// module. It mirrors the RTMP bridge (`HaishinKitEncoderBridge`) but uses
/// SRT-specific connection parameters:
///
/// - **Mode**: caller (default), listener, or rendezvous — set via URL
///   query param `?mode=caller`
/// - **Passphrase**: Optional AES encryption key (10–79 characters) — set
///   via `?passphrase=mySecretKey`
/// - **Latency**: Milliseconds of buffer for network jitter (default 120ms)
///   — set via `?latency=200`
/// - **Stream ID**: Server-side routing identifier — automatically added
///   from the `streamKey` parameter
///
/// SRT is preferred over RTMP for streaming over unreliable networks
/// (cellular, public Wi-Fi) because it handles packet loss and jitter
/// natively with ARQ (Automatic Repeat reQuest).
///
/// ## URL Format
///
/// SRT URLs follow the standard SRT URI format:
/// ```
/// srt://hostname:port?mode=caller&latency=120&passphrase=secret
/// ```
///
/// The `streamKey` passed to `connect(url:streamKey:)` is appended as the
/// `streamid` query parameter, which SRT servers use for routing.
///
/// ## How It Works
///
/// 1. A `MediaMixer` captures video/audio from the camera and microphone.
/// 2. The mixer feeds encoded frames into an `SRTStream`.
/// 3. The `SRTStream` wraps frames in MPEG-TS packets and sends them over
///    an `SRTConnection` to the server.
///
/// This is the same `MediaMixer` → `Stream` → `Connection` pipeline used
/// by the RTMP bridge, just with SRT transport instead of RTMP.
final class SRTEncoderBridge: EncoderBridge {

    // MARK: - Fallback

    /// When SRTHaishinKit isn't available (e.g., missing `libsrt` binary),
    /// we delegate everything to a stub so the app still compiles and runs
    /// — it just can't actually stream over SRT.
    private let fallback = StubEncoderBridge()

    // MARK: - Sample Buffer Tap

    /// Optional closure that receives every raw video frame. Used by the
    /// local recording system to save frames to disk while streaming.
    private var sampleBufferTap: SampleBufferTap?

    // MARK: - Tracking State

    /// When the stream started, used to compute `durationMs` in stats.
    private var streamStartDate: Date?

    /// Cached encoder configuration values. These are stored so we can
    /// report them in stats even when the underlying stream doesn't
    /// expose them directly.
    private var configuredResolution = Resolution(width: 1280, height: 720)
    private var configuredFps = 30
    private var configuredVideoBitrateKbps = 2500
    private var configuredAudioBitrateKbps = 128

    /// The video codec currently configured for encoding.
    /// Defaults to H.264 for maximum compatibility.
    private var configuredCodec: VideoCodec = .h264

    // MARK: - SRT Connection Options
    //
    // These are set by `configureSRTOptions()` before `connect()` is called.
    // They get baked into the SRT URL as query parameters.

    /// SRT connection mode (caller, listener, or rendezvous).
    private var srtMode: SRTMode = .caller

    /// Optional AES encryption passphrase (10–79 characters).
    private var srtPassphrase: String?

    /// Buffer latency in milliseconds for jitter resilience.
    private var srtLatencyMs: Int = 120

    /// Optional stream routing ID (separate from the streamKey-based streamid).
    private var srtStreamId: String?

    /// Handle for the async Task spawned by `connect()`.
    ///
    /// We store this so `disconnect()` and `release()` can cancel it.
    /// Without this, a fire-and-forget connect Task can hang indefinitely
    /// if the SRT server never responds — even after the engine gives up
    /// waiting. If the zombie Task eventually succeeds, it would set
    /// `isConnected = true` and start a stats timer on a bridge nobody
    /// watches.
    private var connectTask: Task<Void, Never>?

    // MARK: - Published Properties

    /// Whether the SRT connection is currently active.
    /// SwiftUI views and the streaming engine observe this to know
    /// when we're connected.
    @Published private(set) var isConnected = false

    /// Live stream statistics, updated once per second while connected.
    @Published private(set) var latestStats = StreamStats()

    /// Combine publisher that emits updated stats every second.
    var statsPublisher: AnyPublisher<StreamStats, Never> {
        $latestStats.eraseToAnyPublisher()
    }

    /// Combine publisher that emits whenever the connection state changes.
    /// The engine subscribes to this during live streaming to detect drops.
    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }

    // MARK: - SRTHaishinKit Objects

    // These are only available when SRTHaishinKit can be imported.
    // The `#if canImport` guard ensures the app compiles even without
    // the SRT library (it just falls back to the stub).

    #if canImport(HaishinKit) && canImport(SRTHaishinKit)

    /// The `MediaMixer` captures camera + microphone input and feeds
    /// encoded frames into the SRT stream. This is the same mixer class
    /// used by the RTMP bridge — HaishinKit shares it across protocols.
    private let mixer = MediaMixer()

    /// The SRT connection manages the low-level socket to the SRT server.
    /// It handles the SRT handshake, encryption, and retransmission.
    private var connection = SRTConnection()

    /// The SRT stream receives encoded audio/video from the mixer and
    /// packages them into MPEG-TS packets for transmission over SRT.
    /// Created lazily because it needs a reference to `connection`.
    private lazy var stream = SRTStream(connection: connection)

    /// Weak reference to the Metal preview view. We keep it weak so the
    /// view can be deallocated when the UI dismisses the preview screen.
    private weak var previewView: MTHKView?

    /// Timer that fires every second to collect and publish stream stats.
    private var statsTimer: Timer?

    #endif

    // MARK: - Init

    init() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        // Wire the mixer's output to the SRT stream. This tells the mixer
        // "send all encoded audio/video frames to this stream."
        // startRunning() must be called so the mixer begins forwarding
        // camera/microphone frames to its outputs (stream + preview).
        Task {
            await mixer.addOutput(stream)
            await mixer.startRunning()
        }
        #endif
    }

    // MARK: - Codec Configuration

    /// Configure the video codec for the encoder.
    ///
    /// HaishinKit selects the codec via the `profileLevel` property on
    /// `VideoCodecSettings`. Setting an HEVC profile level tells
    /// VideoToolbox to create an HEVC compression session instead of H.264.
    ///
    /// **Must be called before `connect(url:streamKey:)`** so the encoder
    /// session is created with the correct codec from the start.
    ///
    /// - Parameter codec: The desired video codec (.h264, .h265, or .av1).
    func configureCodec(_ codec: VideoCodec) async {
        configuredCodec = codec

        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        // Read the current settings so we preserve resolution/bitrate.
        var settings = await stream.videoSettings

        switch codec {
        case .h264:
            // H.264 Baseline 3.1 — universal support, HaishinKit default.
            settings.profileLevel = kVTProfileLevel_H264_Baseline_3_1 as String

        case .h265:
            // HEVC Main Auto Level — ~40% better compression than H.264.
            // SRT supports HEVC natively via MPEG-TS, unlike RTMP which
            // requires Enhanced RTMP for H.265 support.
            settings.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String

        case .av1:
            // AV1 — best compression, but HaishinKit 2.x does not yet
            // expose an AV1 format. Fall back to H.264 and log a warning.
            if codec.isHardwareEncodingAvailable {
                print("[SRTEncoderBridge] AV1 requested but HaishinKit does not support AV1 yet. Falling back to H.264.")
            } else {
                print("[SRTEncoderBridge] AV1 hardware encoding not available on this device. Falling back to H.264.")
            }
            settings.profileLevel = kVTProfileLevel_H264_Baseline_3_1 as String
        }

        try? await stream.setVideoSettings(settings)
        #else
        await fallback.configureCodec(codec)
        #endif
    }

    // MARK: - SRT Options

    /// Configure SRT-specific connection parameters.
    ///
    /// These values are stored and then baked into the SRT URL as query
    /// parameters when `connect(url:streamKey:)` is called.
    /// This must be called **before** `connect()`.
    ///
    /// - Parameters:
    ///   - mode: Connection mode (caller = connect out, listener = accept in,
    ///           rendezvous = simultaneous connect for NAT traversal).
    ///   - passphrase: AES encryption key (10–79 chars). Nil = no encryption.
    ///   - latencyMs: Jitter buffer in milliseconds. Higher = more resilient
    ///                but more delay. Default 120ms works for most networks.
    ///   - streamId: Optional routing ID used by some SRT servers.
    func configureSRTOptions(
        mode: SRTMode,
        passphrase: String?,
        latencyMs: Int,
        streamId: String?
    ) {
        self.srtMode = mode
        self.srtPassphrase = passphrase
        self.srtLatencyMs = latencyMs
        self.srtStreamId = streamId
    }

    // MARK: - Camera

    /// Attach the specified camera and start capturing video.
    ///
    /// - Parameter position: `.front` for the selfie camera, `.back` for
    ///   the rear camera.
    func attachCamera(device: AVCaptureDevice?) async {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        do {
            try await mixer.attachVideo(device)
        } catch {
            print("[SRTEncoderBridge] Failed to attach camera: \(error)")
        }
        #else
        await fallback.attachCamera(device: device)
        #endif
    }

    /// Stop video capture and release the camera hardware so other apps
    /// (or the lock screen) can use it.
    func detachCamera() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        Task {
            do {
                // Passing `nil` tells the mixer to release the camera.
                try await mixer.attachVideo(nil)
            } catch {
                print("[SRTEncoderBridge] Failed to detach camera: \(error)")
            }
        }
        #else
        fallback.detachCamera()
        #endif
    }

    // MARK: - Audio

    /// Attach the default microphone and start capturing audio.
    func attachAudio() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        let device = AVCaptureDevice.default(for: .audio)
        Task {
            do {
                try await mixer.attachAudio(device)
            } catch {
                print("[SRTEncoderBridge] Failed to attach audio: \(error)")
            }
        }
        #else
        fallback.attachAudio()
        #endif
    }

    /// Stop audio capture and release the microphone.
    func detachAudio() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        Task {
            do {
                // Passing `nil` releases the microphone.
                try await mixer.attachAudio(nil)
            } catch {
                print("[SRTEncoderBridge] Failed to detach audio: \(error)")
            }
        }
        #else
        fallback.detachAudio()
        #endif
    }

    // MARK: - SRT Connection

    /// Connect to an SRT server and begin publishing audio/video.
    ///
    /// ## URL Construction
    ///
    /// The `url` parameter should be an SRT URL like:
    /// ```
    /// srt://live.example.com:9000?latency=200&passphrase=secret
    /// ```
    ///
    /// The `streamKey` is appended as the `streamid` query parameter,
    /// which SRT servers use for stream routing and authentication.
    /// The final URL sent to `SRTConnection` looks like:
    /// ```
    /// srt://live.example.com:9000?latency=200&passphrase=secret&streamid=myStreamKey
    /// ```
    ///
    /// - Parameters:
    ///   - url: The SRT server URL (e.g., "srt://live.example.com:9000").
    ///   - streamKey: The stream identifier used for server-side routing.
    func connect(url: String, streamKey: String) {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        // Cancel any previous connect Task that may still be in-flight.
        // This guards against connect() being called twice (e.g., during
        // a reconnection sequence) — we don't want two Tasks racing to
        // set isConnected and start stats timers.
        connectTask?.cancel()

        connectTask = Task {
            do {
                // Build the full SRT URL with connection options and stream key.
                // Options like latency, passphrase, and mode are baked into
                // the URL as query parameters (SRT's standard approach).
                let srtURL = Self.buildSRTURL(
                    baseURL: url,
                    streamKey: streamKey,
                    mode: srtMode,
                    passphrase: srtPassphrase,
                    latencyMs: srtLatencyMs,
                    streamId: srtStreamId
                )

                // Open the SRT connection. This performs the SRT handshake,
                // which includes encryption negotiation if a passphrase is set.
                try await connection.connect(srtURL)

                // If the Task was cancelled while we were connecting (e.g., the
                // engine gave up after 8 seconds), don't mark as connected.
                guard !Task.isCancelled else { return }

                // Start publishing. SRT doesn't use a "stream name" like RTMP,
                // but the publish() method still kicks off the MPEG-TS muxer
                // and starts sending data over the connection.
                await stream.publish()

                await MainActor.run {
                    self.isConnected = true
                    self.streamStartDate = Date()
                    self.startStatsTimer()
                }
            } catch {
                // If this was a cancellation (e.g., release() cancelled us),
                // exit silently — don't log an error or update state.
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.isConnected = false
                    self.streamStartDate = nil
                    self.stopStatsTimer()
                }
                print("[SRTEncoderBridge] Failed to connect/publish: \(error)")
            }
        }
        #else
        fallback.connect(url: url, streamKey: streamKey)
        #endif
    }

    /// Close the SRT connection gracefully.
    ///
    /// This stops the MPEG-TS muxer, flushes any remaining data, and
    /// closes the SRT socket. The server will see a clean disconnect.
    func disconnect() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        // Cancel any in-flight connect Task before disconnecting.
        // If the engine is calling disconnect() while connect() is still
        // trying to establish the SRT handshake, this ensures the connect
        // Task doesn't later set isConnected = true on a closed socket.
        connectTask?.cancel()
        connectTask = nil

        Task {
            // Close the stream first (stops the muxer and encoding pipeline).
            await stream.close()
            // Then close the connection (closes the SRT socket).
            await connection.close()

            await MainActor.run {
                self.isConnected = false
                self.streamStartDate = nil
                self.stopStatsTimer()
            }
        }
        #else
        fallback.disconnect()
        #endif
    }

    // MARK: - Encoder Settings

    /// Change the video bitrate on the fly.
    ///
    /// This is called by the Adaptive Bitrate (ABR) system when network
    /// conditions change. For example, if packet loss increases, ABR will
    /// lower the bitrate to reduce congestion.
    ///
    /// - Parameter kbps: New bitrate in kilobits per second.
    func setBitrate(_ kbps: Int) async throws {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        configuredVideoBitrateKbps = kbps

        // Read current settings, update bitrate, write back.
        // HaishinKit expects bitrate in bits/second, not kbps.
        var settings = await stream.videoSettings
        settings.bitRate = kbps * 1000
        try await stream.setVideoSettings(settings)

        await MainActor.run {
            latestStats.videoBitrateKbps = kbps
        }
        #else
        try await fallback.setBitrate(kbps)
        #endif
    }

    /// Update the full set of video encoding parameters at once.
    ///
    /// Called when switching quality presets (e.g., from 720p to 1080p)
    /// or when the thermal system requests a quality reduction.
    ///
    /// - Parameters:
    ///   - resolution: New resolution (width × height).
    ///   - fps: New frames per second.
    ///   - bitrateKbps: New bitrate in kilobits per second.
    func setVideoSettings(resolution: Resolution, fps: Int, bitrateKbps: Int) async throws {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        // Cache the new values for stats reporting.
        configuredResolution = resolution
        configuredFps = fps
        configuredVideoBitrateKbps = bitrateKbps

        // Apply all settings to the encoder in one batch.
        var settings = await stream.videoSettings
        settings.videoSize = CGSize(width: resolution.width, height: resolution.height)
        settings.bitRate = bitrateKbps * 1000
        settings.expectedFrameRate = Double(fps)
        try await stream.setVideoSettings(settings)

        // Update the published stats so the UI reflects the new settings.
        await MainActor.run {
            latestStats.resolution = resolution.description
            latestStats.fps = Float(fps)
            latestStats.videoBitrateKbps = bitrateKbps
            latestStats.audioBitrateKbps = configuredAudioBitrateKbps
        }
        #else
        try await fallback.setVideoSettings(
            resolution: resolution,
            fps: fps,
            bitrateKbps: bitrateKbps
        )
        #endif
    }

    /// Force-insert a keyframe (I-frame) into the video stream.
    ///
    /// Called after reconnecting so new viewers can start decoding
    /// immediately without waiting for the next natural keyframe.
    ///
    /// HaishinKit doesn't have a direct "insert keyframe" API, so we
    /// temporarily set `frameInterval` to 0.1 seconds (forcing an
    /// immediate keyframe) and then restore the original interval.
    func requestKeyFrame() async {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        var settings = await stream.videoSettings
        let oldFrameInterval = settings.frameInterval

        // Briefly set a very short frame interval to force a keyframe.
        settings.frameInterval = VideoCodecSettings.frameInterval01
        try? await stream.setVideoSettings(settings)

        // Restore the original interval so we don't flood keyframes.
        settings.frameInterval = oldFrameInterval
        try? await stream.setVideoSettings(settings)
        #else
        await fallback.requestKeyFrame()
        #endif
    }

    // MARK: - Sample Buffer Tap

    /// Register a closure that receives every raw video sample buffer.
    ///
    /// Only one tap can be active at a time — calling this again replaces
    /// the previous tap. Used by the local recording feature to capture
    /// frames while streaming.
    ///
    /// - Parameter tap: The closure to call with each `CMSampleBuffer`.
    func registerSampleBufferTap(_ tap: @escaping SampleBufferTap) {
        sampleBufferTap = tap
        fallback.registerSampleBufferTap(tap)
    }

    /// Remove the currently registered sample buffer tap.
    func clearSampleBufferTap() {
        sampleBufferTap = nil
        fallback.clearSampleBufferTap()
    }

    // MARK: - Local Recording

    /// Whether a local recording is currently in progress.
    /// Delegates to the fallback stub since local recording uses the same
    /// `AVAssetWriter` pipeline regardless of transport protocol.
    var isRecording: Bool {
        return fallback.isRecording
    }

    /// Start recording the stream to a local MP4 file.
    ///
    /// Local recording captures the same audio/video frames being sent to
    /// the SRT server, writing them to an MP4 file on disk. This adds
    /// minimal overhead because the frames are already encoded.
    ///
    /// - Parameter fileURL: The local file URL where the MP4 will be saved.
    /// - Throws: If the file already exists or the writer can't be created.
    func startRecording(to fileURL: URL) async throws {
        // TODO: Implement local recording with SRT when the recording
        // pipeline is wired up. For now, delegate to the stub.
        try await fallback.startRecording(to: fileURL)
    }

    /// Stop the current recording and finalize the MP4 file.
    ///
    /// - Returns: The file URL of the finished recording, or `nil` if no
    ///   recording was in progress.
    @discardableResult
    func stopRecording() async throws -> URL? {
        return try await fallback.stopRecording()
    }

    // MARK: - Preview

    /// Attach a Metal-backed preview view to display the live camera feed.
    ///
    /// The `MTHKView` is a HaishinKit view that renders the camera preview
    /// using Metal for high performance. We add it as an output of the
    /// mixer so it receives raw camera frames directly — this works
    /// regardless of whether the SRT stream is connected or publishing.
    ///
    /// - Parameter view: Must be an `MTHKView` instance.
    func attachPreview(_ view: UIView) {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        guard let mthkView = view as? MTHKView else {
            return
        }

        // Don't re-attach the same view.
        if previewView === mthkView {
            return
        }

        // Remove any previously attached preview view from the mixer.
        if let existing = previewView {
            Task {
                await mixer.removeOutput(existing)
            }
        }

        previewView = mthkView

        // Add the preview as a MIXER output (not a stream output).
        // The mixer sends raw camera frames directly to the preview view.
        Task {
            await mixer.addOutput(mthkView)
        }
        #endif
    }

    /// Remove the camera preview from the mixer's output list.
    func detachPreview() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        guard let existing = previewView else {
            return
        }
        previewView = nil
        Task {
            await mixer.removeOutput(existing)
        }
        #endif
    }

    // MARK: - Video Orientation

    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        Task {
            await mixer.setVideoOrientation(orientation)
        }
        #endif
    }

    // MARK: - Cleanup

    /// Release **all** resources owned by this bridge — fully and synchronously
    /// (from the caller's perspective, since this is `async`).
    ///
    /// This is the proper teardown method. It **must** be awaited so that
    /// every resource is freed before the bridge reference is discarded.
    /// The critical step is `mixer.stopRunning()`: the MediaMixer owns an
    /// AVCaptureSession, and iOS only allows one active capture session at a
    /// time. If we don't await this, the old session stays running and the
    /// next bridge's `mixer.startRunning()` silently fails — which was the
    /// root cause of SRT reconnection failures.
    ///
    /// Cleanup order:
    /// 1. Detach the preview (fire-and-forget; just removes the UI layer).
    /// 2. Close the SRT stream (stops the MPEG-TS muxer and encoding).
    /// 3. Close the SRT connection (closes the SRT socket).
    /// 4. Stop the stats polling timer.
    /// 5. Mark ourselves as disconnected.
    /// 6. Stop the mixer's capture session — **the most important step**.
    /// 7. Release the fallback bridge (no-op in production, but keeps the
    ///    contract consistent).
    func release() async {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        // 0. Cancel any in-flight connect Task. If the engine timed out
        //    waiting for the connection (8s) and called release(), the
        //    connect Task may still be awaiting the SRT handshake. Without
        //    cancelling it, the Task could later set isConnected = true
        //    and start a stats timer on a bridge that nobody watches.
        connectTask?.cancel()
        connectTask = nil

        // 1. Detach the preview layer from the UI.
        detachPreview()

        // 2-3. Close the SRT stream and socket. We await these so the server
        //       sees a clean disconnect and the local socket is freed before
        //       the next bridge tries to bind one.
        await stream.close()
        await connection.close()

        // 4-5. Stop stats polling and mark disconnected on the main actor.
        stopStatsTimer()
        isConnected = false

        // 6. Stop the mixer's AVCaptureSession. Without this await, the old
        //    capture session stays running and blocks the next bridge from
        //    accessing the camera hardware.
        await mixer.stopRunning()
        #endif

        // 7. Release the fallback bridge.
        await fallback.release()
    }

    // MARK: - URL Construction

    /// Build a complete SRT URL with connection options and stream routing.
    ///
    /// SRT URLs follow a standard format where connection options are
    /// passed as query parameters. This method merges:
    /// - User-configured options (mode, passphrase, latency) from the profile
    /// - The stream key as `streamid` for server-side routing
    ///
    /// Options set in the base URL are preserved; profile-level options are
    /// added only if not already present in the URL (URL takes precedence).
    ///
    /// ## Examples
    ///
    /// ```
    /// // Basic: "srt://live.example.com:9000" + key "abc123" + defaults
    /// // → srt://live.example.com:9000?mode=caller&latency=120&streamid=abc123
    ///
    /// // With passphrase:
    /// // → srt://live.example.com:9000?mode=caller&latency=120&passphrase=secret&streamid=abc123
    /// ```
    ///
    /// - Parameters:
    ///   - baseURL: The SRT server URL (may already contain query params).
    ///   - streamKey: The stream identifier to append as `streamid`.
    ///   - mode: SRT connection mode (caller/listener/rendezvous).
    ///   - passphrase: Optional AES encryption passphrase.
    ///   - latencyMs: Buffer latency in milliseconds.
    ///   - streamId: Optional stream routing ID (overrides streamKey for streamid).
    /// - Returns: A `URL` with all options applied, or `nil` if malformed.
    static func buildSRTURL(
        baseURL: String,
        streamKey: String,
        mode: SRTMode = .caller,
        passphrase: String? = nil,
        latencyMs: Int = 120,
        streamId: String? = nil
    ) -> URL? {
        // URLComponents handles proper URL encoding and query param merging.
        guard var components = URLComponents(string: baseURL) else {
            print("[SRTEncoderBridge] Failed to parse SRT URL: \(baseURL)")
            return nil
        }

        // Collect existing query items from the URL. The user may have
        // already specified options directly in the URL string.
        var existingItems = components.queryItems ?? []
        let existingKeys = Set(existingItems.map { $0.name.lowercased() })

        // Add mode if not already in the URL.
        // Mode tells the SRT library how to establish the connection.
        if !existingKeys.contains("mode") {
            existingItems.append(URLQueryItem(name: "mode", value: mode.rawValue))
        }

        // Add latency if not already in the URL.
        // Latency controls the jitter buffer size in milliseconds.
        if !existingKeys.contains("latency") {
            existingItems.append(URLQueryItem(name: "latency", value: String(latencyMs)))
        }

        // Add passphrase if provided and not already in the URL.
        // The passphrase enables AES encryption on the SRT connection.
        if let passphrase, !passphrase.isEmpty, !existingKeys.contains("passphrase") {
            existingItems.append(URLQueryItem(name: "passphrase", value: passphrase))
        }

        // Add stream ID. Priority: explicit srtStreamId > streamKey.
        // The `streamid` param is used by SRT servers for routing.
        if !existingKeys.contains("streamid") {
            let effectiveStreamId = streamId ?? (streamKey.isEmpty ? nil : streamKey)
            if let effectiveStreamId, !effectiveStreamId.isEmpty {
                existingItems.append(URLQueryItem(name: "streamid", value: effectiveStreamId))
            }
        }

        // Only set queryItems if we have any, to avoid a trailing "?".
        if !existingItems.isEmpty {
            components.queryItems = existingItems
        }

        return components.url
    }

    // MARK: - Stats Timer

    #if canImport(HaishinKit) && canImport(SRTHaishinKit)

    /// Start a repeating timer that collects SRT performance data every
    /// second and publishes it as `StreamStats`.
    ///
    /// SRT provides much richer performance data than RTMP, including:
    /// - `mbpsSendRate`: Current sending rate in Megabits/second
    /// - `msRTT`: Round-trip time in milliseconds
    /// - `pktSndDrop`: Number of dropped packets (too late to send)
    ///
    /// We map these into `StreamStats` so the UI shows consistent data
    /// regardless of whether we're streaming over RTMP or SRT.
    private func startStatsTimer() {
        stopStatsTimer()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                // Fetch SRT-specific performance data from the connection.
                // This includes packet loss, RTT, send rate, and more.
                let perfData = await self.connection.performanceData
                let audioSettings = await self.stream.audioSettings

                // Calculate how long we've been streaming.
                let durationMs: Int64
                if let streamStartDate = self.streamStartDate {
                    durationMs = Int64(Date().timeIntervalSince(streamStartDate) * 1000)
                } else {
                    durationMs = 0
                }

                await MainActor.run {
                    if let perfData {
                        // Convert SRT's Mbps send rate to kbps for consistency
                        // with our StreamStats model (which uses kbps everywhere).
                        self.latestStats.videoBitrateKbps = max(0, Int(perfData.mbpsSendRate * 1000))
                        // SRT tracks dropped packets — map to droppedFrames for
                        // the UI's packet-loss indicator.
                        self.latestStats.droppedFrames = Int64(perfData.pktSndDrop)
                    } else {
                        // If we can't get performance data, use the configured
                        // value as a reasonable fallback.
                        self.latestStats.videoBitrateKbps = self.configuredVideoBitrateKbps
                    }
                    self.latestStats.audioBitrateKbps = audioSettings.bitRate / 1000
                    self.latestStats.fps = Float(self.configuredFps)
                    self.latestStats.resolution = self.configuredResolution.description
                    self.latestStats.durationMs = durationMs
                }
            }
        }
    }

    /// Stop the stats collection timer.
    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    #endif
}
