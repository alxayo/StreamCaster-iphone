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
        Task {
            await mixer.addOutput(stream)
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
    func configureCodec(_ codec: VideoCodec) {
        configuredCodec = codec

        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        Task {
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
        }
        #else
        fallback.configureCodec(codec)
        #endif
    }

    // MARK: - Camera

    /// Attach the specified camera and start capturing video.
    ///
    /// - Parameter position: `.front` for the selfie camera, `.back` for
    ///   the rear camera.
    func attachCamera(position: AVCaptureDevice.Position) {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        // Find the built-in wide-angle camera for the requested position.
        let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
        )
        Task {
            do {
                try await mixer.attachVideo(device)
            } catch {
                print("[SRTEncoderBridge] Failed to attach camera: \(error)")
            }
        }
        #else
        fallback.attachCamera(position: position)
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
        Task {
            do {
                // Build the full SRT URL with the stream key as `streamid`.
                let srtURL = Self.buildSRTURL(baseURL: url, streamKey: streamKey)

                // Open the SRT connection. This performs the SRT handshake,
                // which includes encryption negotiation if a passphrase is set.
                try await connection.connect(srtURL)

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
    /// stream so it receives the same frames being sent to the SRT server.
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

        // Remove any previously attached preview view.
        if let existing = previewView {
            Task {
                await stream.removeOutput(existing)
            }
        }

        previewView = mthkView
        Task {
            await stream.addOutput(mthkView)
        }
        #endif
    }

    /// Remove the camera preview from the stream's output list.
    func detachPreview() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        guard let existing = previewView else {
            return
        }
        previewView = nil
        Task {
            await stream.removeOutput(existing)
        }
        #endif
    }

    // MARK: - Cleanup

    /// Release all resources: stop capture, close connections, free encoders.
    ///
    /// Call this when the streaming engine is being torn down (e.g., when
    /// the app is backgrounded or the user leaves the streaming screen).
    func release() {
        #if canImport(HaishinKit) && canImport(SRTHaishinKit)
        detachPreview()
        disconnect()
        #endif
        fallback.release()
    }

    // MARK: - URL Construction

    /// Build a complete SRT URL by appending the stream key as `streamid`.
    ///
    /// SRT URLs follow a standard format where connection options are
    /// passed as query parameters. The stream key is sent as `streamid`,
    /// which SRT servers (like SRT Relay, Nimble Streamer, etc.) use to
    /// identify and route the incoming stream.
    ///
    /// ## Examples
    ///
    /// ```
    /// // Input:  "srt://live.example.com:9000" + "abc123"
    /// // Output: srt://live.example.com:9000?streamid=abc123
    ///
    /// // Input:  "srt://live.example.com:9000?latency=200" + "abc123"
    /// // Output: srt://live.example.com:9000?latency=200&streamid=abc123
    /// ```
    ///
    /// - Parameters:
    ///   - baseURL: The SRT server URL (may already contain query params).
    ///   - streamKey: The stream identifier to append as `streamid`.
    /// - Returns: A `URL` with the stream key appended, or `nil` if the
    ///   base URL is malformed.
    static func buildSRTURL(baseURL: String, streamKey: String) -> URL? {
        // URLComponents handles proper URL encoding and query param merging.
        guard var components = URLComponents(string: baseURL) else {
            print("[SRTEncoderBridge] Failed to parse SRT URL: \(baseURL)")
            return nil
        }

        // Start with any existing query items (latency, passphrase, mode, etc.)
        var queryItems = components.queryItems ?? []

        // Append the stream key as `streamid` if it's not empty.
        // The `streamid` parameter is the SRT equivalent of RTMP's stream key.
        if !streamKey.isEmpty {
            queryItems.append(URLQueryItem(name: "streamid", value: streamKey))
        }

        // Only set queryItems if we have any, to avoid adding a trailing "?"
        // to URLs that have no parameters.
        if !queryItems.isEmpty {
            components.queryItems = queryItems
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
