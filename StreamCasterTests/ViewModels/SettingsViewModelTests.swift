// SettingsViewModelTests.swift
// StreamCasterTests
//
// Unit tests for SettingsViewModel — manages all settings screens.
//
// WHY THESE TESTS MATTER:
// The SettingsViewModel controls what video/audio quality the stream uses.
// If defaults change accidentally (e.g., resolution jumps to 4K), users
// could get poor performance or use too much bandwidth without realizing.
// These tests lock down the expected defaults.
//
// TESTING STRATEGY:
// SettingsViewModel depends on two protocols:
//   1. SettingsRepository — where settings are stored (UserDefaults)
//   2. DeviceCapabilityQuery — what the camera hardware supports
//
// We create simple mock implementations that return known values,
// so tests don't depend on real hardware or UserDefaults state.

import XCTest
import AVFoundation
@testable import StreamCaster

// MARK: - Mock SettingsRepository
// ──────────────────────────────────────────────────────────────────
// A fake settings store that returns hardcoded default values.
// This lets us test the ViewModel without touching UserDefaults.
// In real code, the SettingsRepository reads from UserDefaults;
// here we just return the values we want to test against.
// ──────────────────────────────────────────────────────────────────

private class MockSettingsRepository: SettingsRepository {

    // MARK: - Video defaults (what a new user would see)

    /// Default resolution: 720p (1280×720) — good balance of quality and performance.
    func getResolution() -> Resolution { Resolution(width: 1280, height: 720) }
    func setResolution(_ resolution: Resolution) {}

    /// Default frame rate: 30 fps — smooth enough for most streaming.
    func getFps() -> Int { 30 }
    func setFps(_ fps: Int) {}

    /// Default video bitrate: 2500 kbps (2.5 Mbps) — works on most connections.
    func getVideoBitrate() -> Int { 2500 }
    func setVideoBitrate(_ kbps: Int) {}

    // MARK: - Audio defaults

    /// Default audio bitrate: 128 kbps — good quality for voice and music.
    func getAudioBitrate() -> Int { 128 }
    func setAudioBitrate(_ kbps: Int) {}

    /// Default sample rate: 44100 Hz — CD quality, widely supported.
    func getAudioSampleRate() -> Int { 44100 }
    func setAudioSampleRate(_ hz: Int) {}

    /// Default: stereo enabled — better audio experience for viewers.
    func isStereo() -> Bool { true }
    func setStereo(_ enabled: Bool) {}

    // MARK: - Encoder defaults

    /// Default keyframe interval: 2 seconds — recommended by most platforms.
    func getKeyframeInterval() -> Int { 2 }
    func setKeyframeInterval(_ seconds: Int) {}

    /// Default: Adaptive Bitrate ON — automatically adjusts for network quality.
    func isAbrEnabled() -> Bool { true }
    func setAbrEnabled(_ enabled: Bool) {}

    // MARK: - Camera defaults

    /// Default camera: back camera — most common for streaming.
    func getDefaultCameraPosition() -> AVCaptureDevice.Position { .back }
    func setDefaultCameraPosition(_ position: AVCaptureDevice.Position) {}

    func getDefaultCameraDevice() -> CameraDevice? { nil }
    func setDefaultCameraDevice(_ device: CameraDevice) {}

    func getVideoStabilizationMode() -> AVCaptureVideoStabilizationMode { .off }
    func setVideoStabilizationMode(_ mode: AVCaptureVideoStabilizationMode) {}

    /// Default orientation: landscape (1) — standard for video streaming.
    func getPreferredOrientation() -> Int { 1 }
    func setPreferredOrientation(_ orientation: Int) {}

    // MARK: - Network defaults

    /// Default max reconnect attempts: 5 — try a few times before giving up.
    func getReconnectMaxAttempts() -> Int { 5 }
    func setReconnectMaxAttempts(_ count: Int) {}

    // MARK: - Battery defaults

    /// Default low battery threshold: 10% — warn before it's too late.
    func getLowBatteryThreshold() -> Int { 10 }
    func setLowBatteryThreshold(_ percent: Int) {}

    // MARK: - Minimal Mode defaults

    /// Default: start in minimal mode OFF — most users want the camera preview.
    func isStartInMinimalMode() -> Bool { false }
    func setStartInMinimalMode(_ enabled: Bool) {}

    // MARK: - Recording defaults

    /// Default: local recording OFF — saves storage space for most users.
    func isLocalRecordingEnabled() -> Bool { false }
    func setLocalRecordingEnabled(_ enabled: Bool) {}

    /// Default recording destination: Photos library — easy for users to find.
    func getRecordingDestination() -> RecordingDestination { .photosLibrary }
    func setRecordingDestination(_ destination: RecordingDestination) {}
}

// MARK: - Mock DeviceCapabilityQuery
// ──────────────────────────────────────────────────────────────────
// A fake device capability provider. In real code this asks the
// camera hardware what it supports; here we return a fixed list
// so tests are predictable regardless of which Mac/Simulator runs them.
// ──────────────────────────────────────────────────────────────────

private class MockDeviceCapabilityQuery: DeviceCapabilityQuery {

    /// Pretend the camera supports three common resolutions.
    func supportedResolutions(for camera: AVCaptureDevice.Position) -> [Resolution] {
        [
            Resolution(width: 854, height: 480),   // 480p
            Resolution(width: 1280, height: 720),   // 720p
            Resolution(width: 1920, height: 1080),  // 1080p
        ]
    }

    /// Pretend the camera supports 24, 30, and 60 fps at any resolution.
    func supportedFrameRates(for resolution: Resolution, camera: AVCaptureDevice.Position) -> [Int] {
        [24, 30, 60]
    }

    /// Pretend the device has both front and back cameras.
    func availableCameras() -> [AVCaptureDevice.Position] {
        [.back, .front]
    }

    func availableCameraDevices() -> [CameraDevice] {
        [
            CameraDevice(deviceType: .builtInWideAngleCamera, position: .back, localizedName: "Wide"),
            CameraDevice(deviceType: .builtInUltraWideCamera, position: .back, localizedName: "Ultra Wide"),
            CameraDevice(deviceType: .builtInWideAngleCamera, position: .front, localizedName: "Front"),
        ]
    }

    func supportedStabilizationModes(for camera: CameraDevice) -> [AVCaptureVideoStabilizationMode] {
        [.off, .standard, .cinematic]
    }

    /// Pretend this is a high-end device that can handle 1080p60.
    func isTier1Device() -> Bool { true }
}

// MARK: - SettingsViewModelTests

/// Tests for SettingsViewModel's initial state and display helpers.
/// All tests run on @MainActor because the ViewModel is @MainActor.
@MainActor
final class SettingsViewModelTests: XCTestCase {

    // Fresh ViewModel created before each test with our mock dependencies.
    private var viewModel: SettingsViewModel!

    override func setUp() {
        super.setUp()
        // Inject our mocks so the ViewModel doesn't touch real hardware
        // or UserDefaults. This makes tests fast and deterministic.
        viewModel = SettingsViewModel(
            settingsRepo: MockSettingsRepository(),
            capabilityQuery: MockDeviceCapabilityQuery()
        )
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Video Default Tests
    // ──────────────────────────────────────────────────────────

    /// Verify the default resolution is 720p (1280×720).
    /// 720p is the recommended starting point — high enough quality for
    /// most viewers, low enough bitrate to work on typical connections.
    func testInitialResolutionDefaults() {
        XCTAssertEqual(viewModel.selectedResolution.width, 1280,
                       "Default resolution width should be 1280 (720p)")
        XCTAssertEqual(viewModel.selectedResolution.height, 720,
                       "Default resolution height should be 720 (720p)")
    }

    /// Verify the default frame rate is 30 fps.
    /// 30 fps is smooth enough for most content and uses less bandwidth
    /// than 60 fps. Most streaming platforms recommend 30 fps as default.
    func testInitialFpsDefault() {
        XCTAssertEqual(viewModel.selectedFps, 30,
                       "Default FPS should be 30 — the standard for streaming")
    }

    /// Verify the default video bitrate is 2500 kbps (2.5 Mbps).
    /// This is the sweet spot for 720p30 — good quality without
    /// requiring a blazing-fast internet connection.
    func testInitialBitrateDefault() {
        XCTAssertEqual(viewModel.videoBitrateKbps, 2500,
                       "Default video bitrate should be 2500 kbps")
    }

    /// Verify the default keyframe interval is 2 seconds.
    /// Most streaming platforms (Twitch, YouTube) require keyframes
    /// every 2 seconds for smooth playback and quality switching.
    func testInitialKeyframeInterval() {
        XCTAssertEqual(viewModel.keyframeIntervalSec, 2,
                       "Default keyframe interval should be 2 seconds")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Audio Default Tests
    // ──────────────────────────────────────────────────────────

    /// Verify the default audio bitrate is 128 kbps.
    /// 128 kbps AAC provides good audio quality for both speech
    /// and music without using too much bandwidth.
    func testInitialAudioBitrateDefault() {
        XCTAssertEqual(viewModel.audioBitrateKbps, 128,
                       "Default audio bitrate should be 128 kbps")
    }

    /// Verify the default sample rate is 44100 Hz.
    /// 44.1 kHz is CD quality and the most widely supported rate.
    func testInitialAudioSampleRate() {
        XCTAssertEqual(viewModel.audioSampleRate, 44100,
                       "Default audio sample rate should be 44100 Hz")
    }

    /// Verify stereo is enabled by default.
    /// Stereo audio provides a better experience for viewers,
    /// and modern devices all support 2-channel capture.
    func testInitialStereoEnabled() {
        XCTAssertTrue(viewModel.isStereo,
                      "Stereo should be enabled by default")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Encoder Default Tests
    // ──────────────────────────────────────────────────────────

    /// Verify Adaptive Bitrate is enabled by default.
    /// ABR automatically lowers quality when the network is slow
    /// and raises it when bandwidth improves — a much better
    /// experience than dropping frames or buffering.
    func testInitialAbrEnabled() {
        XCTAssertTrue(viewModel.isAbrEnabled,
                      "Adaptive Bitrate should be enabled by default")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Camera & Orientation Default Tests
    // ──────────────────────────────────────────────────────────

    /// Verify the default camera is the back camera.
    /// Most streamers use the rear camera for higher quality video.
    func testInitialCameraPosition() {
        XCTAssertEqual(viewModel.defaultCameraPosition, .back,
                       "Default camera should be the back camera")
    }

    /// Verify the default orientation is landscape.
    /// Landscape is the standard for video streaming — viewers expect
    /// a widescreen (16:9) image on platforms like Twitch and YouTube.
    func testInitialOrientationIsLandscape() {
        XCTAssertEqual(viewModel.preferredOrientation, "landscape",
                       "Default orientation should be landscape")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Recording Default Tests
    // ──────────────────────────────────────────────────────────

    /// Verify local recording is OFF by default.
    /// Recording uses extra storage and CPU, so it should be opt-in.
    func testInitialLocalRecordingDisabled() {
        XCTAssertFalse(viewModel.isLocalRecordingEnabled,
                       "Local recording should be disabled by default")
    }

    /// Verify the default recording destination is the Photos library.
    /// Most users expect recordings to appear in their Camera Roll.
    func testInitialRecordingDestination() {
        XCTAssertEqual(viewModel.recordingDestination, .photosLibrary,
                       "Default recording destination should be Photos library")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Available Options Tests
    // ──────────────────────────────────────────────────────────

    /// Verify that available resolutions are populated from the device query.
    /// The mock returns three resolutions (480p, 720p, 1080p).
    func testAvailableResolutionsPopulated() {
        XCTAssertEqual(viewModel.availableResolutions.count, 3,
                       "Should have 3 available resolutions from mock device")
    }

    /// Verify that available frame rates are populated for the default resolution.
    /// The mock returns three frame rates (24, 30, 60) for any resolution.
    func testAvailableFrameRatesPopulated() {
        XCTAssertEqual(viewModel.availableFrameRates.count, 3,
                       "Should have 3 available frame rates from mock device")
    }

    /// Verify that available cameras are populated from the device query.
    /// The mock returns both front and back cameras.
    func testAvailableCamerasPopulated() {
        XCTAssertEqual(viewModel.availableCameras.count, 2,
                       "Should have 2 available cameras (front and back)")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Display Helper Tests
    // ──────────────────────────────────────────────────────────

    /// Test the resolution label formatter.
    /// This helper turns a Resolution struct into a string like "720p (1280×720)"
    /// for display in the settings picker.
    func testResolutionLabel() {
        let resolution = Resolution(width: 1280, height: 720)
        let label = viewModel.resolutionLabel(for: resolution)

        // The label should contain the "p" shorthand and the full dimensions.
        XCTAssertEqual(label, "720p (1280×720)",
                       "Resolution label should show '720p (WxH)' format")
    }

    /// Test the camera label formatter for the back camera.
    func testCameraLabelBack() {
        let label = viewModel.cameraLabel(for: .back)
        XCTAssertEqual(label, "Back Camera",
                       "Back camera should be labeled 'Back Camera'")
    }

    /// Test the camera label formatter for the front camera.
    func testCameraLabelFront() {
        let label = viewModel.cameraLabel(for: .front)
        XCTAssertEqual(label, "Front Camera",
                       "Front camera should be labeled 'Front Camera'")
    }

    /// Test the reconnect label for a numeric value.
    func testReconnectLabelNumeric() {
        let label = viewModel.reconnectLabel(for: 5)
        XCTAssertEqual(label, "5",
                       "Reconnect label for 5 should be '5'")
    }

    /// Test the reconnect label for unlimited (Int.max).
    /// Users see "Unlimited" instead of a huge number.
    func testReconnectLabelUnlimited() {
        let label = viewModel.reconnectLabel(for: Int.max)
        XCTAssertEqual(label, "Unlimited",
                       "Reconnect label for Int.max should be 'Unlimited'")
    }
}
