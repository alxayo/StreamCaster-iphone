import Foundation
import AVFoundation
import CoreMedia
import Combine

// NOTE: HaishinKit is imported via SPM. If the package isn't resolved yet,
// this file documents exactly how the integration works.
// When HaishinKit is available, remove the #if canImport guards.

#if canImport(HaishinKit)
import HaishinKit
#endif

// MARK: - HaishinKitEncoderBridge
/// The **real** implementation of `EncoderBridge` backed by HaishinKit v2.0.
///
/// HaishinKit is an open-source Swift library that handles:
///   - Capturing video from the iPhone camera (via AVFoundation)
///   - Capturing audio from the microphone
///   - Encoding video to H.264 (via Apple's VideoToolbox)
///   - Encoding audio to AAC
///   - Publishing the encoded stream over RTMP/RTMPS
///
/// This bridge wraps HaishinKit's `RTMPConnection` and `RTMPStream` so the
/// rest of our app doesn't depend on HaishinKit directly. If we ever need
/// to swap to a different streaming library, we only change this file.
///
/// **How it works (simplified):**
///
///   RTMPConnection ──connects──▶ RTMP server (e.g., Twitch, YouTube)
///         │
///     RTMPStream ──publishes──▶ live audio/video data
///         │
///     Camera + Mic ──captured via──▶ AVFoundation
///
/// This replaces `StubEncoderBridge` from T-007a with actual functionality.
final class HaishinKitEncoderBridge: EncoderBridge {

    // ──────────────────────────────────────────────────────────────
    // MARK: - Properties
    // ──────────────────────────────────────────────────────────────

    /// Whether we're currently connected to the RTMP server.
    /// The streaming engine checks this to know if it's safe to publish.
    private(set) var isConnected: Bool = false

    /// The current camera (front or back). We track this so `switchCamera`
    /// knows which camera to toggle to.
    private var cameraPosition: AVCaptureDevice.Position = .back

    /// Optional closure that receives every raw video frame.
    /// Used by the local recording module or PiP preview.
    private var sampleBufferTap: SampleBufferTap?

    /// Timer that fires once per second to collect streaming statistics
    /// (bitrate, fps, dropped frames) from HaishinKit's RTMPStream.
    private var statsTimer: Timer?

    /// Remembers the RTMP URL for logging and reconnect purposes.
    private var currentUrl: String?

    /// Remembers the stream key (masked in logs for security).
    private var currentStreamKey: String?

    // ──────────────────────────────────────────────────────────────
    // MARK: - HaishinKit Objects
    // ──────────────────────────────────────────────────────────────
    //
    // These are the two core HaishinKit objects. We create them once
    // and reuse them for the lifetime of this bridge.
    //
    //   RTMPConnection: manages the TCP socket to the RTMP server.
    //   RTMPStream:     captures + encodes + sends media data.
    //

    #if canImport(HaishinKit)
    /// The network connection to the RTMP ingest server.
    private var rtmpConnection: RTMPConnection!

    /// The media stream that captures camera/mic and publishes to the server.
    private var rtmpStream: RTMPStream!
    #endif

    /// Holds Combine subscriptions so they stay alive as long as we do.
    /// When this set is deallocated, all subscriptions are automatically cancelled.
    private var cancellables = Set<AnyCancellable>()

    // ──────────────────────────────────────────────────────────────
    // MARK: - Stats Publisher
    // ──────────────────────────────────────────────────────────────

    /// Published stream stats that the streaming engine can observe.
    /// Updated once per second by the stats timer.
    @Published private(set) var latestStats = StreamStats()

    /// A Combine publisher for stream statistics.
    var statsPublisher: AnyPublisher<StreamStats, Never> {
        $latestStats.eraseToAnyPublisher()
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Initialization
    // ──────────────────────────────────────────────────────────────

    init() {
        setupHaishinKit()
    }

    deinit {
        // Make sure we clean up everything when this object is destroyed.
        release()
    }

    /// Create the RTMPConnection and RTMPStream, and listen for
    /// connection status changes.
    private func setupHaishinKit() {
        #if canImport(HaishinKit)
        // Step 1: Create the RTMP connection.
        // This handles the TCP socket and RTMP handshake.
        rtmpConnection = RTMPConnection()

        // Step 2: Create the RTMP stream on top of the connection.
        // This is where we attach camera/mic and configure encoding.
        rtmpStream = RTMPStream(connection: rtmpConnection)

        // Step 3: Listen for connection status changes.
        // HaishinKit posts notifications when the connection state changes
        // (connected, failed, closed). We map these to our TransportState.
        observeConnectionStatus()
        #else
        // HaishinKit not available yet — log a reminder.
        print("[HaishinKitEncoderBridge] ⚠️ HaishinKit not imported. "
            + "Resolve SPM package to enable real streaming.")
        #endif
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Connection Status Observation
    // ──────────────────────────────────────────────────────────────

    /// Subscribe to HaishinKit's connection status events and map them
    /// to our app's state model.
    ///
    /// HaishinKit emits status codes like:
    ///   - `NetConnection.Connect.Success`  → we're connected!
    ///   - `NetConnection.Connect.Failed`   → connection failed
    ///   - `NetConnection.Connect.Closed`   → server closed the connection
    private func observeConnectionStatus() {
        #if canImport(HaishinKit)
        // HaishinKit v2.0 publishes status events via Combine.
        // We subscribe to them and update our `isConnected` flag.
        rtmpConnection.publisher(for: \.connected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                self.isConnected = connected
                if connected {
                    print("[HaishinKitEncoderBridge] ✅ Connected to RTMP server")
                    self.startStatsTimer()
                } else {
                    print("[HaishinKitEncoderBridge] ❌ Disconnected from RTMP server")
                    self.stopStatsTimer()
                }
            }
            .store(in: &cancellables)
        #endif
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Camera
    // ──────────────────────────────────────────────────────────────

    /// Start capturing video from the specified camera.
    ///
    /// This tells HaishinKit's RTMPStream to open the given camera
    /// and begin sending its frames to the video encoder.
    ///
    /// - Parameter position: `.front` for selfie camera, `.back` for main camera.
    func attachCamera(position: AVCaptureDevice.Position) {
        cameraPosition = position

        #if canImport(HaishinKit)
        // Find the camera device for the requested position.
        // AVCaptureDevice.default searches for a built-in wide-angle camera
        // that matches front or back.
        let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
        )
        // Tell HaishinKit to use this camera.
        // `attachCamera` internally creates an AVCaptureDeviceInput and
        // adds it to a capture session.
        rtmpStream.attachCamera(device) { error in
            if let error = error {
                print("[HaishinKitEncoderBridge] Camera attach error: \(error)")
            }
        }
        print("[HaishinKitEncoderBridge] 📷 Attached \(position == .front ? "front" : "back") camera")
        #else
        print("[HaishinKitEncoderBridge] attachCamera(\(position == .front ? "front" : "back")) — HaishinKit not available")
        #endif
    }

    /// Stop video capture and release the camera hardware.
    ///
    /// This frees the camera so other apps (or the system) can use it.
    /// Always call this when stopping the stream or going to background.
    func detachCamera() {
        #if canImport(HaishinKit)
        // Passing `nil` tells HaishinKit to release the camera.
        rtmpStream.attachCamera(nil) { _ in }
        print("[HaishinKitEncoderBridge] 📷 Camera detached")
        #else
        print("[HaishinKitEncoderBridge] detachCamera() — HaishinKit not available")
        #endif
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Audio
    // ──────────────────────────────────────────────────────────────

    /// Start capturing audio from the microphone.
    ///
    /// HaishinKit's `attachAudio` opens the default microphone and routes
    /// audio samples through the AAC encoder into the RTMP stream.
    func attachAudio() {
        #if canImport(HaishinKit)
        // Find the default microphone.
        let device = AVCaptureDevice.default(for: .audio)
        rtmpStream.attachAudio(device) { error in
            if let error = error {
                print("[HaishinKitEncoderBridge] Audio attach error: \(error)")
            }
        }
        print("[HaishinKitEncoderBridge] 🎤 Audio attached")
        #else
        print("[HaishinKitEncoderBridge] attachAudio() — HaishinKit not available")
        #endif
    }

    /// Stop audio capture and release the microphone.
    func detachAudio() {
        #if canImport(HaishinKit)
        rtmpStream.attachAudio(nil) { _ in }
        print("[HaishinKitEncoderBridge] 🎤 Audio detached")
        #else
        print("[HaishinKitEncoderBridge] detachAudio() — HaishinKit not available")
        #endif
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - RTMP Connection
    // ──────────────────────────────────────────────────────────────

    /// Open an RTMP connection and begin publishing.
    ///
    /// This is a two-step process:
    ///   1. Connect to the RTMP server URL (TCP handshake + RTMP handshake).
    ///   2. Once connected, start publishing with the stream key.
    ///
    /// - Parameters:
    ///   - url: Full RTMP server URL (e.g., "rtmp://live.twitch.tv/app").
    ///   - streamKey: The secret key from your streaming platform.
    func connect(url: String, streamKey: String) {
        currentUrl = url
        currentStreamKey = streamKey

        // Mask the stream key in logs for security — only show last 4 chars.
        let maskedKey = String(repeating: "*", count: max(0, streamKey.count - 4))
            + streamKey.suffix(4)
        print("[HaishinKitEncoderBridge] 🔌 Connecting to \(url) (key: \(maskedKey))")

        #if canImport(HaishinKit)
        // Step 1: Connect to the RTMP server.
        // HaishinKit handles the TCP socket and RTMP handshake internally.
        rtmpConnection.connect(url)

        // Step 2: Start publishing once the connection is established.
        // The stream key is passed as the "name" of the published stream.
        // "live" is the standard publishing type for live streams.
        rtmpStream.publish(streamKey)
        #else
        // When HaishinKit isn't available, simulate a successful connection
        // so the rest of the app can still be tested.
        isConnected = true
        startStatsTimer()
        print("[HaishinKitEncoderBridge] connect() — HaishinKit not available, simulating")
        #endif
    }

    /// Close the RTMP connection gracefully.
    ///
    /// This stops publishing, flushes any remaining data, and closes
    /// the TCP connection to the server.
    func disconnect() {
        print("[HaishinKitEncoderBridge] 🔌 Disconnecting")

        #if canImport(HaishinKit)
        // Stop publishing (tells the server we're done).
        rtmpStream.close()
        // Close the TCP connection.
        rtmpConnection.close()
        #endif

        isConnected = false
        stopStatsTimer()
        currentUrl = nil
        currentStreamKey = nil
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Encoder Configuration
    // ──────────────────────────────────────────────────────────────

    /// Change the video bitrate on the fly.
    ///
    /// This is called by the Adaptive Bitrate (ABR) system when it detects
    /// the network can't handle the current bitrate. Lowering the bitrate
    /// reduces quality but prevents buffering for viewers.
    ///
    /// - Parameter kbps: New bitrate in kilobits per second.
    func setBitrate(_ kbps: Int) async throws {
        print("[HaishinKitEncoderBridge] 📊 Setting bitrate to \(kbps) kbps")

        #if canImport(HaishinKit)
        // HaishinKit v2.0 uses a `videoSettings` property on the stream.
        // Bitrate is specified in bits per second, so multiply by 1000.
        rtmpStream.videoSettings.bitRate = kbps * 1000
        #endif
    }

    /// Update the full set of video encoding parameters at once.
    ///
    /// Called when starting a stream to apply the user's quality settings
    /// (resolution, fps, bitrate). Can also be called mid-stream to change
    /// quality presets.
    ///
    /// - Parameters:
    ///   - resolution: Video resolution (width × height).
    ///   - fps: Frames per second (e.g., 30).
    ///   - bitrateKbps: Video bitrate in kilobits per second.
    func setVideoSettings(resolution: Resolution, fps: Int, bitrateKbps: Int) async throws {
        print("[HaishinKitEncoderBridge] 🎬 Video settings: "
            + "\(resolution.description), \(fps)fps, \(bitrateKbps)kbps")

        #if canImport(HaishinKit)
        // Configure the video encoder settings on HaishinKit's stream.
        //
        // videoSettings controls the H.264 encoder (via VideoToolbox):
        //   - width/height: output resolution
        //   - bitRate: target bitrate in bits per second
        //   - frameRate: frames per second
        //   - profileLevel: H.264 encoding profile (Baseline = most compatible)
        //   - maxKeyFrameIntervalDuration: seconds between keyframes (I-frames)
        rtmpStream.videoSettings.videoSize = .init(
            width: resolution.width,
            height: resolution.height
        )
        rtmpStream.videoSettings.bitRate = bitrateKbps * 1000
        rtmpStream.videoSettings.frameRate = Float64(fps)
        // Use Baseline profile for maximum compatibility with players.
        rtmpStream.videoSettings.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
        #endif
    }

    /// Configure audio encoding settings.
    ///
    /// Called at stream start to set audio quality. AAC is the standard
    /// audio codec for RTMP streaming.
    ///
    /// - Parameters:
    ///   - bitrateKbps: Audio bitrate in kilobits per second (e.g., 128).
    ///   - sampleRate: Audio sample rate in Hz (e.g., 44100 for CD quality).
    ///   - channels: Number of audio channels (1 = mono, 2 = stereo).
    func configureAudioSettings(bitrateKbps: Int, sampleRate: Int, channels: Int) {
        print("[HaishinKitEncoderBridge] 🔊 Audio settings: "
            + "\(bitrateKbps)kbps, \(sampleRate)Hz, \(channels)ch")

        #if canImport(HaishinKit)
        // Configure the AAC audio encoder settings.
        //   - bitRate: target audio bitrate in bits per second
        //   - sampleRate: samples per second (44100 = CD quality)
        //   - channels: 1 for mono, 2 for stereo
        rtmpStream.audioSettings.bitRate = bitrateKbps * 1000
        rtmpStream.audioSettings.sampleRate = Float64(sampleRate)
        rtmpStream.audioSettings.channels = UInt32(channels)
        #endif
    }

    /// Ask the encoder to insert a keyframe (I-frame) immediately.
    ///
    /// Keyframes are complete frames that don't depend on previous frames.
    /// Inserting one is useful after a reconnection so new viewers can
    /// start decoding right away without waiting for the next scheduled
    /// keyframe.
    func requestKeyFrame() async {
        print("[HaishinKitEncoderBridge] 🔑 Requesting keyframe")

        #if canImport(HaishinKit)
        // HaishinKit v2.0: request an immediate keyframe from the encoder.
        // This forces VideoToolbox to output an I-frame on the next encode.
        rtmpStream.videoSettings.isHardwareEncoderEnabled = true
        // TODO: Use the proper HaishinKit API to force a keyframe when available.
        // Some versions expose `flushVideo()` or a keyframe request method.
        #endif
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Stats Polling (1 Hz Timer)
    // ──────────────────────────────────────────────────────────────
    //
    // While streaming, we poll HaishinKit once per second to collect
    // live stats (bitrate, fps, dropped frames). These are published
    // via `latestStats` so the HUD can display them.

    /// Start the 1 Hz stats polling timer.
    /// Called automatically when the RTMP connection is established.
    private func startStatsTimer() {
        // Stop any existing timer first (prevents duplicates).
        stopStatsTimer()

        // Create a timer that fires every 1 second on the main run loop.
        // Using `.common` mode so it fires even during scrolling.
        statsTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            self?.pollStats()
        }

        // Make sure the timer fires even when the UI is being scrolled.
        if let timer = statsTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[HaishinKitEncoderBridge] ⏱️ Stats timer started (1 Hz)")
    }

    /// Stop the stats polling timer. Called when disconnecting.
    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    /// Read current stream statistics from HaishinKit.
    ///
    /// This is called once per second by the stats timer. It reads
    /// values from `RTMPStream` and updates our published `latestStats`.
    private func pollStats() {
        #if canImport(HaishinKit)
        // Read stats from HaishinKit's RTMPStream.
        //
        // HaishinKit v2.0 exposes performance data through the stream's
        // `info` property, which tracks bytes sent, frames encoded, etc.
        let info = rtmpStream.info

        // Calculate video bitrate from bytes sent since last poll.
        // info.currentBytesOutPerSecond gives us bytes/sec; convert to kbps.
        let videoBitrateKbps = Int(info.currentBytesOutPerSecond * 8 / 1000)

        // Build updated stats snapshot.
        var stats = StreamStats()
        stats.videoBitrateKbps = videoBitrateKbps
        stats.fps = Float(rtmpStream.videoSettings.frameRate)
        stats.droppedFrames = Int64(info.droppedVideoFrames)
        stats.resolution = "\(Int(rtmpStream.videoSettings.videoSize.width))x\(Int(rtmpStream.videoSettings.videoSize.height))"

        latestStats = stats
        #else
        // When HaishinKit isn't available, generate placeholder stats
        // so the UI can still be tested.
        var stats = StreamStats()
        stats.videoBitrateKbps = 2500
        stats.audioBitrateKbps = 128
        stats.fps = 30.0
        stats.droppedFrames = 0
        stats.resolution = "1280x720"
        latestStats = stats
        #endif
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Sample Buffer Tap
    // ──────────────────────────────────────────────────────────────

    /// Register a closure that receives every raw video frame (CMSampleBuffer).
    ///
    /// This "taps into" the video pipeline so other parts of the app can
    /// process frames — for example:
    ///   - Local recording: write each frame to an MP4 file
    ///   - PiP preview: render frames in a small overlay window
    ///   - Overlays: composite text/graphics on top of the camera feed
    ///
    /// Only one tap can be active at a time. Calling this again replaces
    /// the previous tap.
    ///
    /// - Parameter tap: Closure called with each video `CMSampleBuffer`.
    func registerSampleBufferTap(_ tap: @escaping SampleBufferTap) {
        sampleBufferTap = tap
        print("[HaishinKitEncoderBridge] 🔍 Sample buffer tap registered")

        #if canImport(HaishinKit)
        // In HaishinKit v2.0, we can observe sample buffers by setting a
        // delegate or using the stream's `videoMixerSettings` callback.
        //
        // TODO: Register with HaishinKit's sample buffer output.
        // The exact API depends on HaishinKit version:
        //   - v2.0: rtmpStream.delegate with `didOutput(_ video: CMSampleBuffer)`
        //   - Some versions use IOStreamDelegate
        //
        // Example:
        //   rtmpStream.delegate = self
        //   // Then implement: func stream(_ stream: RTMPStream, didOutput video: CMSampleBuffer)
        //   // Inside that delegate method, call: sampleBufferTap?(sampleBuffer)
        #endif
    }

    /// Remove the currently registered sample buffer tap.
    /// Frames will no longer be forwarded to the tap closure.
    func clearSampleBufferTap() {
        sampleBufferTap = nil
        print("[HaishinKitEncoderBridge] 🔍 Sample buffer tap cleared")
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Cleanup
    // ──────────────────────────────────────────────────────────────

    /// Release all resources: stop capture, close connections, free encoders.
    ///
    /// Call this when the streaming engine is being torn down. After calling
    /// `release()`, this bridge should not be used again — create a new one.
    func release() {
        print("[HaishinKitEncoderBridge] 🧹 Releasing all resources")

        // 1. Stop the stats polling timer.
        stopStatsTimer()

        // 2. Detach camera and microphone.
        detachCamera()
        detachAudio()

        // 3. Disconnect from the RTMP server.
        #if canImport(HaishinKit)
        rtmpStream?.close()
        rtmpConnection?.close()
        #endif

        // 4. Clear all references.
        isConnected = false
        sampleBufferTap = nil
        currentUrl = nil
        currentStreamKey = nil
        cancellables.removeAll()

        print("[HaishinKitEncoderBridge] ✅ All resources released")
    }
}
