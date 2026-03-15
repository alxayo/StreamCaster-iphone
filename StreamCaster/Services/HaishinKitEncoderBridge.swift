import Foundation
import AVFoundation
import CoreMedia
import Combine
import CoreGraphics
import UIKit

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

    @Published private(set) var isConnected = false

    @Published private(set) var latestStats = StreamStats()

    var statsPublisher: AnyPublisher<StreamStats, Never> {
        $latestStats.eraseToAnyPublisher()
    }

    #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
    private let mixer = MediaMixer()
    private let connection = RTMPConnection()
    private lazy var stream = RTMPStream(connection: connection)
    private weak var previewView: MTHKView?
    private var statsTimer: Timer?
    #endif

    init() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        Task {
            await mixer.addOutput(stream)
        }
        #endif
    }

    func attachCamera(position: AVCaptureDevice.Position) {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
        )
        Task {
            do {
                try await mixer.attachVideo(device)
            } catch {
                print("[HaishinKitEncoderBridge] Failed to attach camera: \(error)")
            }
        }
        #else
        fallback.attachCamera(position: position)
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

    func detachPreview() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        guard let existing = previewView else {
            return
        }
        previewView = nil
        Task {
            await stream.removeOutput(existing)
        }
        #endif
    }

    func release() {
        #if canImport(HaishinKit) && canImport(RTMPHaishinKit)
        detachPreview()
        disconnect()
        #endif
        fallback.release()
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