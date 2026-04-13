import XCTest
import UIKit
import AVFoundation
import Combine
@testable import StreamCaster

// =============================================================================
// MARK: - Mock Encoder Bridge
// =============================================================================

/// A test double ("mock") that records every call made to it.
///
/// WHY DO WE NEED THIS?
/// The real encoder bridge talks to hardware (camera, microphone, RTMP server).
/// We can't use real hardware in unit tests, so we create a fake version that:
///   1. Does nothing when called (no-op).
///   2. Records *what* was called and *what arguments* were passed.
/// This lets us verify the EncoderController calls the right bridge methods
/// in the right order, without needing a physical device.
///
/// WHY @unchecked Sendable?
/// EncoderController is an `actor`, which means it runs on its own thread.
/// Swift requires anything shared across threads to be `Sendable`.
/// We mark this `@unchecked Sendable` because the actor guarantees
/// serialized access — only one call happens at a time.
private final class MockEncoderBridge: EncoderBridge, @unchecked Sendable {

    // -------------------------------------------------------------------------
    // MARK: Call Tracking Properties
    // -------------------------------------------------------------------------
    // These properties let test methods check exactly what happened.

    /// How many times `setBitrate(_:)` was called.
    var setBitrateCallCount = 0

    /// The last bitrate value passed to `setBitrate(_:)`.
    var lastBitrateKbps: Int?

    /// How many times `setVideoSettings(...)` was called.
    var setVideoSettingsCallCount = 0

    /// The last resolution passed to `setVideoSettings(...)`.
    var lastVideoResolution: Resolution?

    /// The last FPS passed to `setVideoSettings(...)`.
    var lastVideoFps: Int?

    /// The last bitrate passed to `setVideoSettings(...)`.
    var lastVideoBitrateKbps: Int?

    /// How many times `attachCamera(device:)` was called.
    var attachCameraCallCount = 0

    /// The last device passed to `attachCamera(device:)`.
    var lastCameraDevice: AVCaptureDevice?

    /// How many times `detachCamera()` was called.
    var detachCameraCallCount = 0

    /// How many times `requestKeyFrame()` was called.
    var requestKeyFrameCallCount = 0

    /// An ordered log of every method call, stored as plain strings.
    var callLog: [String] = []

    // -------------------------------------------------------------------------
    // MARK: Stubbed Properties
    // -------------------------------------------------------------------------

    var isConnected: Bool = false

    // -------------------------------------------------------------------------
    // MARK: Camera (no-op implementations)
    // -------------------------------------------------------------------------

    func attachCamera(device: AVCaptureDevice?) async {
        attachCameraCallCount += 1
        lastCameraDevice = device
        callLog.append("attachCamera")
    }

    func setVideoStabilization(_ mode: AVCaptureVideoStabilizationMode) {
        callLog.append("setVideoStabilization")
    }

    /// The last orientation passed to `setVideoOrientation(_:)`.
    var lastVideoOrientation: AVCaptureVideoOrientation?

    /// How many times `setVideoOrientation(_:)` was called.
    var setVideoOrientationCallCount = 0

    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        setVideoOrientationCallCount += 1
        lastVideoOrientation = orientation
        callLog.append("setVideoOrientation")
    }

    /// Records the call; does nothing else.
    func detachCamera() {
        detachCameraCallCount += 1
        callLog.append("detachCamera")
    }

    // -------------------------------------------------------------------------
    // MARK: Audio (no-op implementations)
    // -------------------------------------------------------------------------

    func attachAudio() {
        callLog.append("attachAudio")
    }

    func detachAudio() {
        callLog.append("detachAudio")
    }

    // -------------------------------------------------------------------------
    // MARK: RTMP Connection (no-op implementations)
    // -------------------------------------------------------------------------

    func connect(url: String, streamKey: String) {
        callLog.append("connect")
    }

    func disconnect() {
        callLog.append("disconnect")
    }

    // -------------------------------------------------------------------------
    // MARK: Encoder Configuration (recording implementations)
    // -------------------------------------------------------------------------

    /// Records which codec was configured. No-op for mock purposes.
    func configureCodec(_ codec: VideoCodec) async {
        callLog.append("configureCodec")
    }

    /// Records the bitrate change. This is the "instant" path that doesn't
    /// require an encoder restart.
    func setBitrate(_ kbps: Int) async throws {
        setBitrateCallCount += 1
        lastBitrateKbps = kbps
        callLog.append("setBitrate")
    }

    /// Records the full video settings change. This is called during an
    /// encoder restart (the "heavy" path).
    func setVideoSettings(resolution: Resolution, fps: Int, bitrateKbps: Int) async throws {
        setVideoSettingsCallCount += 1
        lastVideoResolution = resolution
        lastVideoFps = fps
        lastVideoBitrateKbps = bitrateKbps
        callLog.append("setVideoSettings")
    }

    /// Records that a keyframe was requested.
    func requestKeyFrame() async {
        requestKeyFrameCallCount += 1
        callLog.append("requestKeyFrame")
    }

    // -------------------------------------------------------------------------
    // MARK: Sample Buffer Tap (no-op implementations)
    // -------------------------------------------------------------------------

    func registerSampleBufferTap(_ tap: @escaping SampleBufferTap) {
        callLog.append("registerSampleBufferTap")
    }

    func clearSampleBufferTap() {
        callLog.append("clearSampleBufferTap")
    }

    // -------------------------------------------------------------------------
    // MARK: Local Recording (no-op implementations)
    // -------------------------------------------------------------------------

    var isRecording: Bool = false

    func startRecording(to fileURL: URL) async throws {
        callLog.append("startRecording")
    }

    @discardableResult
    func stopRecording() async throws -> URL? {
        callLog.append("stopRecording")
        return nil
    }

    // -------------------------------------------------------------------------
    // MARK: Cleanup (no-op implementation)
    // -------------------------------------------------------------------------

    func release() {
        callLog.append("release")
    }

    // -------------------------------------------------------------------------
    // MARK: Preview (no-op implementations)
    // -------------------------------------------------------------------------

    func attachPreview(_ view: UIView) {
        callLog.append("attachPreview")
    }

    func detachPreview() {
        callLog.append("detachPreview")
    }

    // -------------------------------------------------------------------------
    // MARK: Stats (no-op implementation)
    // -------------------------------------------------------------------------

    @Published var latestStats = StreamStats()

    var statsPublisher: AnyPublisher<StreamStats, Never> {
        $latestStats.eraseToAnyPublisher()
    }
}

// =============================================================================
// MARK: - EncoderController Tests
// =============================================================================

/// Tests for the EncoderController actor.
///
/// WHY ARE ALL TESTS `async`?
/// EncoderController is a Swift `actor`. To read its properties or call its
/// methods from outside, you must use `await`. That means every test function
/// needs to be marked `async` (and `throws` if it calls throwing methods).
///
/// WHAT'S THE PATTERN?
/// Each test follows "Arrange → Act → Assert":
///   1. Arrange: Create a mock bridge and controller with known initial state.
///   2. Act: Call the method being tested.
///   3. Assert: Check the mock's recorded calls and the controller's state.
final class EncoderControllerTests: XCTestCase {

    // -------------------------------------------------------------------------
    // MARK: - Test Helpers
    // -------------------------------------------------------------------------

    /// Creates a standard 720p / 30fps / 2500 kbps test config.
    /// Using a helper keeps tests short and consistent.
    private func makeDefaultConfig() -> StreamConfig {
        StreamConfig(
            profileId: "test-profile",
            resolution: Resolution(width: 1280, height: 720),
            fps: 30,
            videoBitrateKbps: 2500
        )
    }

    /// Creates a fresh controller + mock bridge pair for each test.
    ///
    /// "SUT" stands for "System Under Test" — a common testing abbreviation.
    /// Each test gets its own instances so they don't interfere with each other.
    ///
    /// - Parameter config: Optional custom config. Uses 720p defaults if nil.
    /// - Returns: A tuple of (controller to test, mock to inspect).
    private func makeSUT(
        config: StreamConfig? = nil
    ) -> (EncoderController, MockEncoderBridge) {
        let bridge = MockEncoderBridge()
        let testConfig = config ?? makeDefaultConfig()
        let controller = EncoderController(
            encoderBridge: bridge,
            initialConfig: testConfig
        )
        return (controller, bridge)
    }

    // -------------------------------------------------------------------------
    // MARK: - Test: Initial State
    // -------------------------------------------------------------------------

    /// Verify that the controller's initial state matches the config passed in.
    ///
    /// WHY THIS MATTERS:
    /// If the controller starts with wrong values, every subsequent quality
    /// change would compare against the wrong baseline and make bad decisions.
    func testInitialStateMatchesConstructorParams() async {
        // Arrange: create a controller with known 720p settings
        let (controller, _) = makeSUT()

        // Act: read back all three state properties
        // (we use `await` because the controller is an actor)
        let resolution = await controller.currentResolution
        let fps = await controller.currentFps
        let bitrate = await controller.currentBitrateKbps

        // Assert: all values should match what we passed in
        XCTAssertEqual(
            resolution,
            Resolution(width: 1280, height: 720),
            "Resolution should be 1280×720 from the initial config"
        )
        XCTAssertEqual(fps, 30, "FPS should be 30 from the initial config")
        XCTAssertEqual(bitrate, 2500, "Bitrate should be 2500 kbps from the initial config")
    }

    // -------------------------------------------------------------------------
    // MARK: - Test: Bitrate-Only Change Is Immediate
    // -------------------------------------------------------------------------

    /// When ABR only changes the bitrate (same resolution & FPS), the
    /// controller should call `setBitrate` — NOT do a full encoder restart.
    ///
    /// WHY THIS MATTERS:
    /// Encoder restarts are expensive (camera detach → reconfigure → reattach).
    /// If only the bitrate changes, we can adjust it instantly without any
    /// visible glitch to the viewer. This test ensures we take the fast path.
    func testBitrateOnlyChangeIsImmediate() async throws {
        // Arrange
        let (controller, bridge) = makeSUT()

        // Act: request a bitrate change without specifying resolution/fps.
        // Passing nil for resolution and fps means "keep current values."
        try await controller.requestAbrChange(bitrateKbps: 3000)

        // Assert: setBitrate was called with the new value
        XCTAssertEqual(
            bridge.setBitrateCallCount, 1,
            "setBitrate should be called exactly once"
        )
        XCTAssertEqual(
            bridge.lastBitrateKbps, 3000,
            "setBitrate should receive the new bitrate value"
        )

        // Assert: NO restart methods were called
        XCTAssertEqual(
            bridge.detachCameraCallCount, 0,
            "detachCamera should NOT be called for bitrate-only changes"
        )
        XCTAssertEqual(
            bridge.setVideoSettingsCallCount, 0,
            "setVideoSettings should NOT be called for bitrate-only changes"
        )
        XCTAssertEqual(
            bridge.attachCameraCallCount, 0,
            "attachCamera should NOT be called for bitrate-only changes"
        )

        // Assert: controller state was updated
        let updatedBitrate = await controller.currentBitrateKbps
        XCTAssertEqual(
            updatedBitrate, 3000,
            "Controller should track the new bitrate internally"
        )
    }

    // -------------------------------------------------------------------------
    // MARK: - Test: Resolution Change Requires Restart
    // -------------------------------------------------------------------------

    /// When ABR changes the resolution, the controller must do a full restart:
    /// detach camera → update settings → reattach camera → request keyframe.
    ///
    /// WHY THIS MATTERS:
    /// iOS hardware encoders can't change resolution on the fly. We must stop
    /// capturing, reconfigure, and start again. This test verifies the full
    /// restart sequence happens in the correct order.
    func testResolutionChangeRequiresRestart() async throws {
        // Arrange: start at 720p
        let (controller, bridge) = makeSUT()

        // Act: request a change to 1080p (different resolution = restart needed)
        try await controller.requestAbrChange(
            bitrateKbps: 4000,
            resolution: Resolution(width: 1920, height: 1080),
            fps: 30
        )

        // Assert: the full restart sequence happened
        XCTAssertEqual(bridge.detachCameraCallCount, 1, "Camera should be detached once")
        XCTAssertEqual(bridge.setVideoSettingsCallCount, 1, "Video settings should be updated once")
        XCTAssertEqual(bridge.attachCameraCallCount, 1, "Camera should be reattached once")
        XCTAssertEqual(bridge.requestKeyFrameCallCount, 1, "A keyframe should be requested once")

        // Assert: setBitrate was NOT called separately
        // (the bitrate is included in setVideoSettings during a restart)
        XCTAssertEqual(
            bridge.setBitrateCallCount, 0,
            "setBitrate should NOT be called during a restart — setVideoSettings handles it"
        )

        // Assert: methods were called in the correct order.
        // Order matters! Detach must happen before settings change,
        // and attach must happen after settings are applied.
        let expectedSequence = [
            "detachCamera",      // Step 1: stop capturing frames
            "setVideoSettings",  // Step 2: apply new resolution/fps/bitrate
            "attachCamera",      // Step 3: resume capturing with new settings
            "requestKeyFrame"    // Step 4: send a keyframe so viewers can decode
        ]
        XCTAssertEqual(
            bridge.callLog, expectedSequence,
            "Restart sequence must follow: detach → settings → attach → keyframe"
        )

        // Assert: correct values were passed to setVideoSettings
        XCTAssertEqual(bridge.lastVideoResolution, Resolution(width: 1920, height: 1080))
        XCTAssertEqual(bridge.lastVideoFps, 30)
        XCTAssertEqual(bridge.lastVideoBitrateKbps, 4000)

        // Assert: controller state was updated to reflect new settings
        let resolution = await controller.currentResolution
        let bitrate = await controller.currentBitrateKbps
        XCTAssertEqual(resolution, Resolution(width: 1920, height: 1080))
        XCTAssertEqual(bitrate, 4000)
    }

    // -------------------------------------------------------------------------
    // MARK: - Test: Thermal Cooldown Prevents Rapid Changes
    // -------------------------------------------------------------------------

    /// Two thermal changes in rapid succession — the second should be rejected.
    ///
    /// WHY THIS MATTERS:
    /// When a device is right on a thermal boundary, the temperature can
    /// fluctuate rapidly. Without a cooldown, the encoder would restart over
    /// and over (720p → 480p → 720p → 480p...), creating a terrible experience.
    /// The 60-second cooldown prevents this "thermal oscillation."
    func testThermalCooldownPreventsRapidChanges() async throws {
        // Arrange: start at 720p
        let (controller, bridge) = makeSUT()

        // Act 1: first thermal change — drop from 720p to 480p.
        // This should succeed because no thermal change has happened yet
        // (lastThermalRestartTime starts at .distantPast).
        try await controller.requestThermalChange(
            resolution: Resolution(width: 854, height: 480),
            fps: 30
        )
        XCTAssertEqual(
            bridge.detachCameraCallCount, 1,
            "First thermal change should trigger a restart"
        )

        // Act 2: second thermal change immediately — should be BLOCKED.
        // The 60-second cooldown started when the first change completed.
        do {
            try await controller.requestThermalChange(
                resolution: Resolution(width: 640, height: 360),
                fps: 24
            )
            XCTFail("Second thermal change should throw — cooldown is active")
        } catch let error as EncoderControllerError {
            // Assert: we got the right error type with a reasonable remaining time
            if case .thermalCooldownActive(let remaining) = error {
                XCTAssertGreaterThan(
                    remaining, 0,
                    "Remaining cooldown should be positive"
                )
                XCTAssertLessThanOrEqual(
                    remaining, 60,
                    "Remaining cooldown should be at most 60 seconds"
                )
            } else {
                XCTFail("Expected thermalCooldownActive error, got: \(error)")
            }
        }

        // Assert: only ONE restart happened (the first one)
        XCTAssertEqual(
            bridge.detachCameraCallCount, 1,
            "Only the first thermal change should have triggered a restart"
        )
    }

    // -------------------------------------------------------------------------
    // MARK: - Test: Bitrate Change Bypasses Thermal Cooldown
    // -------------------------------------------------------------------------

    /// ABR bitrate-only changes should work even during the thermal cooldown.
    ///
    /// WHY THIS MATTERS:
    /// The thermal cooldown only applies to resolution/FPS changes (which need
    /// a restart). Bitrate changes are lightweight and don't affect thermal
    /// load, so they should always be allowed. This ensures ABR can still
    /// optimize bandwidth even when the device is thermally constrained.
    func testBitrateChangeBypassesThermalCooldown() async throws {
        // Arrange: start at 720p, then trigger a thermal change to start cooldown
        let (controller, bridge) = makeSUT()

        // Trigger a thermal change (starts the 60s cooldown)
        try await controller.requestThermalChange(
            resolution: Resolution(width: 854, height: 480),
            fps: 30
        )
        XCTAssertEqual(bridge.detachCameraCallCount, 1, "Thermal change should restart encoder")

        // Act: request a bitrate-only ABR change during the cooldown window.
        // This should succeed because ABR bitrate changes don't check
        // the thermal cooldown — they go through the fast path.
        try await controller.requestAbrChange(bitrateKbps: 1500)

        // Assert: setBitrate was called successfully
        XCTAssertEqual(
            bridge.setBitrateCallCount, 1,
            "Bitrate change should succeed despite thermal cooldown"
        )
        XCTAssertEqual(bridge.lastBitrateKbps, 1500)

        // Assert: no additional restart happened (still only the thermal one)
        XCTAssertEqual(
            bridge.detachCameraCallCount, 1,
            "Bitrate-only change should not trigger another restart"
        )

        // Assert: controller tracks the new bitrate
        let bitrate = await controller.currentBitrateKbps
        XCTAssertEqual(bitrate, 1500)
    }

    // -------------------------------------------------------------------------
    // MARK: - Test: Blacklisted Config Is Rejected
    // -------------------------------------------------------------------------

    /// A config that was blacklisted (caused overheating before) should be
    /// rejected when thermal restoration tries to use it.
    ///
    /// WHY THIS MATTERS:
    /// If a resolution+FPS combo causes the device to overheat, we don't want
    /// to keep trying it. Blacklisting prevents an infinite cycle of:
    /// "restore to 1080p → overheat → drop to 720p → restore to 1080p → ..."
    func testBlacklistedConfigIsRejected() async throws {
        // Arrange: create a controller and blacklist 1080p@30
        let (controller, _) = makeSUT()
        let blacklistedResolution = Resolution(width: 1920, height: 1080)
        await controller.blacklistConfig(resolution: blacklistedResolution, fps: 30)

        // Act: try to restore to the blacklisted config
        do {
            try await controller.requestThermalRestore(
                resolution: blacklistedResolution,
                fps: 30,
                bitrateKbps: 4000
            )
            XCTFail("Should have thrown configBlacklisted error")
        } catch let error as EncoderControllerError {
            // Assert: the error identifies the exact blacklisted config
            if case .configBlacklisted(let config) = error {
                XCTAssertEqual(
                    config, "1920x1080@30",
                    "Error should contain the blacklisted config key"
                )
            } else {
                XCTFail("Expected configBlacklisted error, got: \(error)")
            }
        }
    }
}
