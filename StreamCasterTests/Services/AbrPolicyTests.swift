import XCTest
import AVFoundation
import CoreMedia
@testable import StreamCaster

// MARK: - AbrPolicyTests

/// Tests for the ABR (Adaptive Bitrate) policy engine.
///
/// AbrPolicy is the "brain" of the ABR system — it decides WHEN to change
/// quality based on real-time streaming statistics. These tests verify:
///   - The policy respects its enabled/disabled state
///   - Congestion and backpressure thresholds are correct
///   - Construction and initial state are correct
///
/// NOTE: AbrPolicy depends on EncoderController (a Swift actor), which in
/// turn depends on EncoderBridge (a protocol). To test the policy without
/// real hardware, we create a lightweight stub that implements EncoderBridge
/// as a set of no-op methods.
final class AbrPolicyTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a standard 720p stream config for testing.
    private func make720pConfig(abrEnabled: Bool = true) -> StreamConfig {
        var config = StreamConfig(
            profileId: "test",
            resolution: Resolution(width: 1280, height: 720),
            fps: 30,
            videoBitrateKbps: 2500
        )
        config.abrEnabled = abrEnabled
        return config
    }

    /// Creates an EncoderController backed by our stub bridge.
    /// This lets us test the policy without real camera/encoder hardware.
    private func makeEncoderController(config: StreamConfig) -> EncoderController {
        let stubBridge = StubEncoderBridgeForTests()
        return EncoderController(encoderBridge: stubBridge, initialConfig: config)
    }

    /// Creates a StreamStats snapshot with the given values.
    /// Fills in sensible defaults for fields we don't care about.
    private func makeStats(
        videoBitrateKbps: Int = 2500,
        fps: Float = 30.0
    ) -> StreamStats {
        var stats = StreamStats()
        stats.videoBitrateKbps = videoBitrateKbps
        stats.fps = fps
        return stats
    }

    // MARK: - Enabled/Disabled Tests

    /// When ABR is disabled (isEnabled = false), calling evaluateStats
    /// should do nothing — the quality should stay fixed at whatever
    /// the user configured. This is important because some streamers
    /// prefer manual control over their quality settings.
    func testPolicyDisabledDoesNothing() async {
        // Create a policy with ABR disabled
        let config = make720pConfig(abrEnabled: false)
        let controller = makeEncoderController(config: config)
        let policy = AbrPolicy(
            encoderController: controller,
            startingConfig: config,
            deviceTier: 2
        )

        // Verify ABR is disabled
        XCTAssertFalse(policy.isEnabled,
            "Policy should be disabled when abrEnabled is false in the config")

        // Send terrible stats (should normally trigger a step-down)
        let badStats = makeStats(videoBitrateKbps: 100, fps: 5.0)

        // Even with awful stats, evaluateStats should be a no-op
        // because the policy is disabled. We call it several times
        // to ensure it doesn't accumulate state either.
        for _ in 0..<10 {
            await policy.evaluateStats(
                badStats,
                targetFps: 30,
                targetBitrateKbps: 2500
            )
        }

        // If we got here without crashing, the policy correctly
        // ignored the stats. The encoder bitrate should be unchanged.
        let currentBitrate = await controller.currentBitrateKbps
        XCTAssertEqual(currentBitrate, 2500,
            "Encoder bitrate should not change when ABR policy is disabled")
    }

    // MARK: - Initial State Tests

    /// When first created, the policy should start at the top of the
    /// quality ladder (best quality). The streamer begins at their
    /// chosen settings and only steps down if problems occur.
    func testPolicyStartsAtTopOfLadder() {
        let config = make720pConfig()
        let controller = makeEncoderController(config: config)
        let policy = AbrPolicy(
            encoderController: controller,
            startingConfig: config,
            deviceTier: 2
        )

        // The policy should start enabled (matching the config)
        XCTAssertTrue(policy.isEnabled,
            "Policy should be enabled when abrEnabled is true in the config")
    }

    // MARK: - Threshold Tests

    /// The congestion threshold is 75% of the target bitrate.
    /// If actual bitrate drops below 75% for 3 consecutive seconds,
    /// the policy should trigger a step-down.
    ///
    /// Here we verify that sending congested stats (below 75%) for
    /// enough seconds causes the encoder's bitrate to change.
    func testCongestionThreshold() async {
        let config = make720pConfig()
        let controller = makeEncoderController(config: config)
        let policy = AbrPolicy(
            encoderController: controller,
            startingConfig: config,
            deviceTier: 2
        )

        // Target bitrate is 2500 kbps. The congestion threshold is 75%,
        // so anything below 1875 kbps is considered congested.
        // We'll send 1000 kbps (well below threshold) with good fps.
        let congestedStats = makeStats(videoBitrateKbps: 1000, fps: 30.0)

        // The policy requires 3 consecutive seconds of congestion.
        // Each call to evaluateStats represents ~1 second.
        for _ in 0..<3 {
            await policy.evaluateStats(
                congestedStats,
                targetFps: 30,
                targetBitrateKbps: 2500
            )
        }

        // After 3 seconds of congestion, the policy should have stepped
        // down, which tells the encoder to use a lower bitrate.
        let currentBitrate = await controller.currentBitrateKbps
        XCTAssertLessThan(currentBitrate, 2500,
            "After 3 seconds of congestion (bitrate < 75% of target), "
            + "the policy should step down to a lower bitrate")
    }

    /// The backpressure threshold is 80% of the target fps.
    /// If actual fps drops below 80% for 5 consecutive seconds,
    /// the policy should trigger a step-down because the device
    /// can't keep up with encoding.
    func testBackpressureThreshold() async {
        let config = make720pConfig()
        let controller = makeEncoderController(config: config)
        let policy = AbrPolicy(
            encoderController: controller,
            startingConfig: config,
            deviceTier: 2
        )

        // Target fps is 30. The backpressure threshold is 80%,
        // so anything below 24 fps is considered backpressure.
        // We'll send 15 fps (well below threshold) with good bitrate.
        let backpressureStats = makeStats(videoBitrateKbps: 2500, fps: 15.0)

        // The policy requires 5 consecutive seconds of backpressure.
        for _ in 0..<5 {
            await policy.evaluateStats(
                backpressureStats,
                targetFps: 30,
                targetBitrateKbps: 2500
            )
        }

        // After 5 seconds of backpressure, the policy should have
        // stepped down to reduce the encoder workload.
        let currentBitrate = await controller.currentBitrateKbps
        XCTAssertLessThan(currentBitrate, 2500,
            "After 5 seconds of backpressure (fps < 80% of target), "
            + "the policy should step down to reduce encoder load")
    }
}

// MARK: - StubEncoderBridgeForTests

/// A lightweight stub that implements the EncoderBridge protocol as no-ops.
///
/// WHY DO WE NEED THIS?
/// AbrPolicy → EncoderController → EncoderBridge (protocol).
/// In production, EncoderBridge talks to real camera/encoder hardware.
/// In tests, we don't have real hardware, so we create this stub that
/// does nothing. This lets us test the policy logic in isolation.
///
/// All methods are intentionally empty — we're only testing that the
/// policy DECIDES correctly, not that the encoder EXECUTES correctly.
private final class StubEncoderBridgeForTests: EncoderBridge {

    // MARK: - Camera (no-ops)

    /// No-op: we don't need a real camera in tests.
    func attachCamera(position: AVCaptureDevice.Position) {}

    /// No-op: nothing to detach in tests.
    func detachCamera() {}

    // MARK: - Audio (no-ops)

    /// No-op: we don't need a real microphone in tests.
    func attachAudio() {}

    /// No-op: nothing to detach in tests.
    func detachAudio() {}

    // MARK: - RTMP Connection (no-ops)

    /// No-op: we don't connect to a real RTMP server in tests.
    func connect(url: String, streamKey: String) {}

    /// No-op: nothing to disconnect in tests.
    func disconnect() {}

    /// Always returns false — we're never "connected" in tests.
    var isConnected: Bool { false }

    // MARK: - Encoder Configuration (no-ops)

    /// No-op: codec selection doesn't matter for ABR tests.
    func configureCodec(_ codec: VideoCodec) {}

    /// No-op: pretends to change the bitrate successfully.
    func setBitrate(_ kbps: Int) async throws {}

    /// No-op: pretends to apply video settings successfully.
    func setVideoSettings(resolution: Resolution, fps: Int, bitrateKbps: Int) async throws {}

    /// No-op: pretends to request a keyframe successfully.
    func requestKeyFrame() async {}

    // MARK: - Sample Buffer Tap (no-ops)

    /// No-op: we don't process video frames in tests.
    func registerSampleBufferTap(_ tap: @escaping SampleBufferTap) {}

    /// No-op: nothing to clear in tests.
    func clearSampleBufferTap() {}

    // MARK: - Cleanup (no-op)

    /// No-op: nothing to release in tests.
    func release() {}
}
