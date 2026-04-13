import Foundation
import AVFoundation
import CoreMedia
import Combine
import CoreGraphics
import UIKit
import VideoToolbox

#if canImport(HaishinKit)
import HaishinKit
#endif

#if canImport(RTMPHaishinKit)
import RTMPHaishinKit
#endif

// MARK: - HaishinKitEncoderBridge
final class HaishinKitEncoderBridge: EncoderBridge {
    private let fallback = StubEncoderBridge()
    private var sampleBufferTap: SampleBufferTap?
    private var streamStartDate: Date?
    private var configuredResolution = Resolution(width: 1280, height: 720)
    private var configuredFps = 30
    private var configuredVideoBitrateKbps = 2500
    private var configuredAudioBitrateKbps = 128

    /// The video codec currently configured for encoding.
    /// Defaults to H.264 for maximum compatibility with all RTMP servers.
    private var configuredCodec: VideoCodec = .h264

    @Published private(set) var isConnected = false

    @Published private(set) var latestStats = StreamStats()

    var statsPublisher: AnyPublisher<StreamStats, Never> {
        $latestStats.eraseToAnyPublisher()
    }

    /// Whether a local MP4 recording is currently in progress.
    /// Updated whenever recording starts or stops.
    private(set) var isRecording = false

    #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
    private let mixer = MediaMixer()
    private let connection = RTMPConnection()
    private lazy var stream = RTMPStream(connection: connection)
    private weak var previewView: MTHKView?
    private var statsTimer: Timer?

    /// HaishinKit's built-in recorder. It conforms to `MediaMixerOutput`,
    /// so we attach it to the mixer and it receives the same audio/video
    /// frames that go out over RTMP — no extra encoding needed.
    private var recorder: StreamRecorder?
    #endif

    init() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            // Wire the mixer → stream pipeline and start the capture session.
            // startRunning() must be called so the mixer begins forwarding
            // camera/microphone frames to its outputs (stream + preview).
            await mixer.addOutput(stream)
            await mixer.startRunning()
        }
        #endif
    }

    /// Configure the video codec for the encoder.
    ///
    /// HaishinKit selects the codec via the `profileLevel` property on
    /// `VideoCodecSettings`.  Setting an HEVC profile level tells
    /// VideoToolbox to create an HEVC (H.265) compression session instead
    /// of an H.264 session.
    ///
    /// **Must be called before `connect(url:streamKey:)`** so the encoder
    /// session is created with the correct codec.
    ///
    /// - Parameter codec: The desired video codec (.h264, .h265, or .av1).
    func configureCodec(_ codec: VideoCodec) async {
        configuredCodec = codec

        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        // Read the current settings so we preserve resolution/bitrate/etc.
        var settings = await stream.videoSettings

        switch codec {
        case .h264:
            // H.264 — universal support.
            // Use Baseline 3.1 which is the HaishinKit default.
            settings.profileLevel = kVTProfileLevel_H264_Baseline_3_1 as String

        case .h265:
            // H.265 (HEVC) — ~40% better compression than H.264.
            // Setting an HEVC profile level automatically switches the
            // internal `format` to `.hevc`, which tells VideoToolbox to
            // use kCMVideoCodecType_HEVC.
            // Requires Enhanced RTMP server support.
            settings.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String

        case .av1:
            // AV1 — best compression, but HaishinKit 2.x does not
            // expose an AV1 format in VideoCodecSettings.Format.
            // We fall back to H.264 and log a warning.
            //
            // TODO: When HaishinKit adds AV1 support, update this
            // branch to use the appropriate profile level / format.
            if codec.isHardwareEncodingAvailable {
                print("[HaishinKitEncoderBridge] AV1 requested but HaishinKit does not support AV1 yet. Falling back to H.264.")
            } else {
                print("[HaishinKitEncoderBridge] AV1 hardware encoding not available on this device. Falling back to H.264.")
            }
            settings.profileLevel = kVTProfileLevel_H264_Baseline_3_1 as String
        }

        try? await stream.setVideoSettings(settings)
        #else
        await fallback.configureCodec(codec)
        #endif
    }

    func attachCamera(device: AVCaptureDevice?) {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            do {
                try await mixer.attachVideo(device)
            } catch {
                print("[HaishinKitEncoderBridge] Failed to attach camera: \(error)")
            }
        }
        #else
        fallback.attachCamera(device: device)
        #endif
    }

    func setVideoStabilization(_ mode: AVCaptureVideoStabilizationMode) {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            do {
                try await mixer.configuration(video: 0) { unit in
                    unit.preferredVideoStabilizationMode = mode
                }
            } catch {
                print("[HaishinKitEncoderBridge] Failed to set stabilization: \(error)")
            }
        }
        #endif
    }

    func detachCamera() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            do {
                try await mixer.attachVideo(nil)
            } catch {
                print("[HaishinKitEncoderBridge] Failed to detach camera: \(error)")
            }
        }
        #else
        fallback.detachCamera()
        #endif
    }

    func attachAudio() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        let device = AVCaptureDevice.default(for: .audio)
        Task {
            do {
                try await mixer.attachAudio(device)
            } catch {
                print("[HaishinKitEncoderBridge] Failed to attach audio: \(error)")
            }
        }
        #else
        fallback.attachAudio()
        #endif
    }

    func detachAudio() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            do {
                try await mixer.attachAudio(nil)
            } catch {
                print("[HaishinKitEncoderBridge] Failed to detach audio: \(error)")
            }
        }
        #else
        fallback.detachAudio()
        #endif
    }

    func connect(url: String, streamKey: String) {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            do {
                _ = try await connection.connect(url)
                _ = try await stream.publish(streamKey)
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
                print("[HaishinKitEncoderBridge] Failed to connect/publish: \(error)")
            }
        }
        #else
        fallback.connect(url: url, streamKey: streamKey)
        #endif
    }

    func disconnect() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            _ = try? await stream.close()
            try? await connection.close()
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

    func setBitrate(_ kbps: Int) async throws {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        configuredVideoBitrateKbps = kbps
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

    func setVideoSettings(resolution: Resolution, fps: Int, bitrateKbps: Int) async throws {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        configuredResolution = resolution
        configuredFps = fps
        configuredVideoBitrateKbps = bitrateKbps

        var settings = await stream.videoSettings
        settings.videoSize = CGSize(width: resolution.width, height: resolution.height)
        settings.bitRate = bitrateKbps * 1000
        settings.expectedFrameRate = Double(fps)
        try await stream.setVideoSettings(settings)

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

    func requestKeyFrame() async {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        var settings = await stream.videoSettings
        let oldFrameInterval = settings.frameInterval
        settings.frameInterval = VideoCodecSettings.frameInterval01
        try? await stream.setVideoSettings(settings)
        settings.frameInterval = oldFrameInterval
        try? await stream.setVideoSettings(settings)
        #else
        await fallback.requestKeyFrame()
        #endif
    }

    func registerSampleBufferTap(_ tap: @escaping SampleBufferTap) {
        sampleBufferTap = tap
        fallback.registerSampleBufferTap(tap)
    }

    func clearSampleBufferTap() {
        sampleBufferTap = nil
        fallback.clearSampleBufferTap()
    }

    func attachPreview(_ view: UIView) {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        guard let mthkView = view as? MTHKView else {
            return
        }

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
        // The mixer sends raw camera frames directly to the preview view,
        // which works regardless of whether the RTMP stream is connected.
        // Using stream.addOutput() only works for playback (receiving
        // remote video) — not for publishing (sending camera video).
        Task {
            await mixer.addOutput(mthkView)
        }
        #endif
    }

    func detachPreview() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        guard let existing = previewView else {
            return
        }
        previewView = nil
        Task {
            await mixer.removeOutput(existing)
        }
        #endif
    }

    func release() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        // Stop any in-progress recording before tearing down.
        if isRecording {
            Task {
                try? await stopRecording()
            }
        }
        detachPreview()
        disconnect()
        // Stop the mixer's capture session to release camera/mic resources.
        Task {
            await mixer.stopRunning()
        }
        #endif
        fallback.release()
    }

    // MARK: - Local Recording

    /// Start recording the current stream to a local MP4 file.
    ///
    /// Under the hood we use HaishinKit's `StreamRecorder`, which is an
    /// actor that conforms to `MediaMixerOutput`. We add it to the mixer
    /// so it receives the same A/V frames that go to the RTMP stream.
    /// This means recording uses the *already-encoded* data — there is
    /// **no** extra encoding step, keeping CPU and battery usage low.
    ///
    /// We also enable `movieFragmentInterval` (10 s) so the file is
    /// written incrementally. If the app crashes, the file up to the
    /// last fragment is still playable.
    ///
    /// - Parameter fileURL: Absolute path where the `.mp4` will be saved.
    func startRecording(to fileURL: URL) async throws {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        // Don't start a second recording on top of an existing one.
        guard recorder == nil else {
            print("[HaishinKitEncoderBridge] Recording already in progress — ignoring startRecording.")
            return
        }

        // Build recording settings that match the current codec choice.
        // If H.265 is configured we tell AVAssetWriter to write HEVC;
        // otherwise we default to H.264 for maximum compatibility.
        let videoCodecType: AVVideoCodecType = (configuredCodec == .h265)
            ? .hevc
            : .h264

        let recordingSettings: [AVMediaType: [String: any Sendable]] = [
            .audio: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 0,           // 0 → auto-detect from source
                AVNumberOfChannelsKey: 0       // 0 → auto-detect from source
            ],
            .video: [
                AVVideoCodecKey: videoCodecType,
                AVVideoHeightKey: 0,           // 0 → auto-detect from source
                AVVideoWidthKey: 0             // 0 → auto-detect from source
            ]
        ]

        // Create a fresh recorder, wire it to the mixer, and start writing.
        let newRecorder = StreamRecorder()

        // Movie fragment interval of 10 s means the file is written in
        // chunks. If the app crashes mid-recording, everything up to the
        // last 10-second boundary is still playable.
        await newRecorder.setMovieFragmentInterval(10.0)

        // Attach the recorder as a mixer output so it receives frames.
        await mixer.addOutput(newRecorder)

        // Start writing to the specified file URL.
        try await newRecorder.startRecording(fileURL, settings: recordingSettings)

        // Save the reference so we can stop later.
        recorder = newRecorder
        isRecording = true
        print("[HaishinKitEncoderBridge] Recording started → \(fileURL.lastPathComponent)")
        #else
        try await fallback.startRecording(to: fileURL)
        isRecording = fallback.isRecording
        #endif
    }

    /// Stop the current recording and finalize the MP4 file.
    ///
    /// This tells the `StreamRecorder` to finish writing, which flushes
    /// any buffered samples and writes the final MP4 trailer (moov atom).
    /// After this call the file at the returned URL is a valid, playable MP4.
    ///
    /// - Returns: The URL of the completed recording, or `nil` if no
    ///   recording was active.
    @discardableResult
    func stopRecording() async throws -> URL? {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        guard let activeRecorder = recorder else {
            print("[HaishinKitEncoderBridge] No active recording to stop.")
            isRecording = false
            return nil
        }

        // Finalize the file — this flushes remaining frames and writes
        // the MP4 moov atom so the file is playable.
        let outputURL = try await activeRecorder.stopRecording()

        // Detach the recorder from the mixer so it stops receiving frames.
        await mixer.removeOutput(activeRecorder)

        // Clean up our reference.
        recorder = nil
        isRecording = false
        print("[HaishinKitEncoderBridge] Recording stopped → \(outputURL.lastPathComponent)")
        return outputURL
        #else
        let result = try await fallback.stopRecording()
        isRecording = false
        return result
        #endif
    }

    #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
    private func startStatsTimer() {
        stopStatsTimer()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                let info = await self.stream.info
                let audioSettings = await self.stream.audioSettings
                let durationMs: Int64
                if let streamStartDate = self.streamStartDate {
                    durationMs = Int64(Date().timeIntervalSince(streamStartDate) * 1000)
                } else {
                    durationMs = 0
                }

                await MainActor.run {
                    self.latestStats.videoBitrateKbps = max(0, (info.currentBytesPerSecond * 8) / 1000)
                    self.latestStats.audioBitrateKbps = audioSettings.bitRate / 1000
                    self.latestStats.fps = Float(self.configuredFps)
                    self.latestStats.resolution = self.configuredResolution.description
                    self.latestStats.durationMs = durationMs
                }
            }
        }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
    #endif
}