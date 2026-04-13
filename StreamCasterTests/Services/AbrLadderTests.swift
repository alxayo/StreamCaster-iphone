import XCTest
@testable import StreamCaster

// MARK: - AbrLadderTests

/// Tests for the ABR (Adaptive Bitrate) quality ladder.
///
/// The ABR ladder is a "staircase" of quality levels. When the network is fast,
/// we stream at the top step (best quality). When it slows down, we step down
/// to lower quality to avoid buffering. These tests verify that:
///   - The ladder is built correctly for different device tiers
///   - Navigation (step up, step down, reset) works as expected
///   - Edge cases and safety nets behave properly
final class AbrLadderTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a standard 720p stream config for testing.
    /// Most tests use this as a baseline — 720p at 30fps and 2500 kbps.
    private func make720pConfig() -> StreamConfig {
        StreamConfig(
            profileId: "test",
            resolution: Resolution(width: 1280, height: 720),
            fps: 30,
            videoBitrateKbps: 2500
        )
    }

    /// Creates a 1080p stream config for testing higher-quality scenarios.
    /// 1080p at 30fps and 4500 kbps — the highest quality the app supports.
    private func make1080pConfig() -> StreamConfig {
        StreamConfig(
            profileId: "test",
            resolution: Resolution(width: 1920, height: 1080),
            fps: 30,
            videoBitrateKbps: 4500
        )
    }

    /// Creates a very low bitrate config for testing minimum-bitrate filtering.
    /// 480p at 30fps but only 300 kbps — some sub-steps will fall below
    /// the 200 kbps minimum and should be excluded.
    private func makeLowBitrateConfig() -> StreamConfig {
        StreamConfig(
            profileId: "test",
            resolution: Resolution(width: 854, height: 480),
            fps: 30,
            videoBitrateKbps: 300
        )
    }

    // MARK: - Ladder Building Tests

    /// Verify that the ladder steps go from highest to lowest quality.
    /// Step 0 should have the highest bitrate; the last step should
    /// have the lowest. This ensures stepping DOWN always reduces quality.
    func testBuildLadderCreatesStepsInDescendingQualityOrder() {
        // Build a 720p ladder on a mid-range device
        let ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // The ladder must have at least 2 steps to be useful
        XCTAssertGreaterThan(ladder.steps.count, 1,
            "Ladder should have multiple steps for quality adjustment")

        // First step (index 0) = best quality = highest bitrate
        let firstBitrate = ladder.steps.first!.bitrateKbps
        let lastBitrate = ladder.steps.last!.bitrateKbps
        XCTAssertGreaterThan(firstBitrate, lastBitrate,
            "First step should have a higher bitrate than the last step")
    }

    /// Device tier 1 (older iPhones) should be capped at 720p.
    /// Even if the user asks for 1080p, the ladder should never include
    /// any 1080p steps because old hardware can't handle it.
    func testBuildLadderTier1CapsAt720p() {
        // Ask for 1080p on a tier-1 (old/slow) device
        let ladder = AbrLadder.buildLadder(
            startingConfig: make1080pConfig(),
            deviceTier: 1
        )

        // Check every single step — none should be 1080p (1920 wide)
        for step in ladder.steps {
            XCTAssertLessThanOrEqual(step.resolution.width, 1280,
                "Tier 1 devices should never have steps wider than 1280 pixels (720p)")
            XCTAssertLessThanOrEqual(step.resolution.height, 720,
                "Tier 1 devices should never have steps taller than 720 pixels (720p)")
        }
    }

    /// Device tier 3 (flagship iPhones) should include 1080p steps
    /// when the starting config is 1080p. These devices have the
    /// processing power to handle Full HD streaming.
    func testBuildLadderTier3Allows1080p() {
        // Ask for 1080p on a tier-3 (flagship) device
        let ladder = AbrLadder.buildLadder(
            startingConfig: make1080pConfig(),
            deviceTier: 3
        )

        // The first step should be at 1080p (1920×1080)
        let topStep = ladder.steps.first!
        XCTAssertEqual(topStep.resolution.width, 1920,
            "Tier 3 devices should include 1080p (1920 wide) as the top step")
        XCTAssertEqual(topStep.resolution.height, 1080,
            "Tier 3 devices should include 1080p (1080 tall) as the top step")
    }

    /// Each resolution level should have bitrate sub-steps at 100%, 75%, and 50%.
    /// These sub-steps let the ABR system make small adjustments without
    /// changing resolution (which requires an expensive encoder restart).
    func testBuildLadderIncludesBitrateSubSteps() {
        let config = make720pConfig() // 720p at 2500 kbps
        let ladder = AbrLadder.buildLadder(
            startingConfig: config,
            deviceTier: 2
        )

        // The 720p resolution should have 3 bitrate sub-steps: 100%, 75%, 50%
        // For a 2500 kbps starting bitrate, that's 2500, 1875, 1250
        let stepsAt720p = ladder.steps.filter {
            $0.resolution.width == 1280 && $0.resolution.height == 720
        }

        // We expect at least 3 sub-steps (100%, 75%, 50%) at the starting resolution
        XCTAssertGreaterThanOrEqual(stepsAt720p.count, 3,
            "720p should have at least 3 bitrate sub-steps (100%, 75%, 50%)")

        // Verify the expected bitrate values for the starting resolution
        let bitrates = stepsAt720p.map { $0.bitrateKbps }
        XCTAssertTrue(bitrates.contains(2500),
            "Should include 100% bitrate step (2500 kbps)")
        XCTAssertTrue(bitrates.contains(1875),
            "Should include 75% bitrate step (1875 kbps)")
        XCTAssertTrue(bitrates.contains(1250),
            "Should include 50% bitrate step (1250 kbps)")
    }

    /// The very last steps in the ladder should reduce frame rate as a
    /// last resort. Dropping FPS is very noticeable to viewers, so it
    /// only happens after all bitrate and resolution reductions are exhausted.
    func testBuildLadderIncludesFrameRateReduction() {
        let ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // The last few steps should have reduced FPS (24 and 15).
        // These are the "emergency" quality levels.
        let lastSteps = ladder.steps.suffix(3)
        let fpsValues = lastSteps.map { $0.fps }

        // At least one step should have 15 fps (the lowest emergency fps)
        XCTAssertTrue(fpsValues.contains(15),
            "Ladder should include 15 fps as a last-resort step")

        // At least one step should have 24 fps (film-like, less jarring than 15)
        XCTAssertTrue(fpsValues.contains(24),
            "Ladder should include 24 fps as a last-resort step")
    }

    // MARK: - Step Navigation Tests

    /// Calling stepDown() should move to a lower quality step.
    /// After stepping down, the current step should have a lower (or equal)
    /// bitrate than before.
    func testStepDownReturnsLowerQuality() {
        var ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // Record the original bitrate at the top of the ladder
        let originalBitrate = ladder.currentStep.bitrateKbps

        // Step down one level
        let newStep = ladder.stepDown()

        // stepDown should return the new (lower quality) step
        XCTAssertNotNil(newStep,
            "stepDown() should return the new step when not at the bottom")

        // The new step should have a lower bitrate
        XCTAssertLessThan(newStep!.bitrateKbps, originalBitrate,
            "After stepping down, the bitrate should be lower")
    }

    /// When already at the bottom of the ladder (lowest quality), stepping
    /// down further should return nil — there's nowhere lower to go.
    func testStepDownAtBottomReturnsNil() {
        var ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // Walk all the way to the bottom of the ladder
        while ladder.canStepDown {
            _ = ladder.stepDown()
        }

        // Now we're at the bottom — stepping down should return nil
        let result = ladder.stepDown()
        XCTAssertNil(result,
            "stepDown() should return nil when already at the lowest quality")
    }

    /// Calling stepUp() should move to a higher quality step.
    /// After stepping up, the current step should have a higher bitrate.
    func testStepUpReturnsHigherQuality() {
        var ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // First, step down so we have room to step up
        _ = ladder.stepDown()
        let lowerBitrate = ladder.currentStep.bitrateKbps

        // Now step back up
        let newStep = ladder.stepUp()

        // stepUp should return the new (higher quality) step
        XCTAssertNotNil(newStep,
            "stepUp() should return the new step when not at the top")

        // The new step should have a higher bitrate
        XCTAssertGreaterThan(newStep!.bitrateKbps, lowerBitrate,
            "After stepping up, the bitrate should be higher")
    }

    /// When already at the top of the ladder (best quality), stepping
    /// up further should return nil — there's nowhere higher to go.
    func testStepUpAtTopReturnsNil() {
        var ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // We start at the top (index 0), so stepping up should fail
        let result = ladder.stepUp()
        XCTAssertNil(result,
            "stepUp() should return nil when already at the highest quality")
    }

    /// After calling reset(), the ladder should go back to index 0,
    /// which is the best quality step. This is called when starting
    /// a new streaming session.
    func testResetReturnsToTopOfLadder() {
        var ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // Step down a few times so we're NOT at the top
        _ = ladder.stepDown()
        _ = ladder.stepDown()
        XCTAssertGreaterThan(ladder.currentIndex, 0,
            "Should have moved away from the top before testing reset")

        // Reset back to the top
        ladder.reset()

        // Should be back at index 0 (best quality)
        XCTAssertEqual(ladder.currentIndex, 0,
            "After reset(), currentIndex should be 0 (best quality)")
    }

    // MARK: - Computed Property Tests

    /// canStepDown should be true when we're not at the very bottom.
    /// This tells the ABR policy whether it's possible to reduce quality.
    func testCanStepDownWhenNotAtBottom() {
        let ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // At the top of the ladder, there should be steps below us
        XCTAssertTrue(ladder.canStepDown,
            "canStepDown should be true when not at the bottom of the ladder")
    }

    /// canStepUp should be true when we're not at the very top.
    /// This tells the ABR policy whether it's possible to increase quality.
    func testCanStepUpWhenNotAtTop() {
        var ladder = AbrLadder.buildLadder(
            startingConfig: make720pConfig(),
            deviceTier: 2
        )

        // Step down first so we're NOT at the top
        _ = ladder.stepDown()

        // Now we should be able to step back up
        XCTAssertTrue(ladder.canStepUp,
            "canStepUp should be true when not at the top of the ladder")
    }

    // MARK: - Description Format Test

    /// The step description should be a human-readable string like
    /// "1280x720@30fps 2500kbps". This is used in log messages.
    func testStepDescriptionFormat() {
        // Create a step with known values
        let step = AbrLadder.Step(
            resolution: Resolution(width: 1280, height: 720),
            fps: 30,
            bitrateKbps: 2500
        )

        // Verify the exact format: "WIDTHxHEIGHT@FPSfps BITRATEkbps"
        XCTAssertEqual(step.description, "1280x720@30fps 2500kbps",
            "Step description should match the format 'WIDTHxHEIGHT@FPSfps BITRATEkbps'")
    }

    // MARK: - Safety & Constraint Tests

    /// No step in the ladder should ever have a higher bitrate than the
    /// user's starting config. The ladder only goes DOWN in quality,
    /// never UP beyond what the user originally requested.
    func testBuildLadderNeverExceedsStartingBitrate() {
        let config = make720pConfig() // 2500 kbps
        let ladder = AbrLadder.buildLadder(
            startingConfig: config,
            deviceTier: 2
        )

        // Every single step must be at or below the starting bitrate
        for step in ladder.steps {
            XCTAssertLessThanOrEqual(step.bitrateKbps, config.videoBitrateKbps,
                "Step \(step.description) exceeds the starting bitrate of \(config.videoBitrateKbps) kbps")
        }
    }

    /// Steps with a bitrate below 200 kbps should be excluded from the
    /// ladder. Video below 200 kbps is unwatchable, so there's no point
    /// including those steps.
    func testBuildLadderMinimumBitrateFilter() {
        // Use a low starting bitrate — some sub-steps will fall below 200
        let ladder = AbrLadder.buildLadder(
            startingConfig: makeLowBitrateConfig(),
            deviceTier: 2
        )

        // Every step must be at least 200 kbps
        for step in ladder.steps {
            XCTAssertGreaterThanOrEqual(step.bitrateKbps, 200,
                "Step \(step.description) is below the 200 kbps minimum — it should have been filtered out")
        }
    }

    /// Even with unusual inputs, the ladder should always have at least
    /// one step. An empty ladder would cause a crash (index out of bounds).
    /// This tests the safety-net code path.
    func testEmptyLadderSafetyNet() {
        // Create a config with an absurdly tiny resolution that won't
        // match any of the resolution presets
        let tinyConfig = StreamConfig(
            profileId: "test",
            resolution: Resolution(width: 100, height: 100),
            fps: 30,
            videoBitrateKbps: 50
        )

        // Even with this weird config, the ladder should have at least 1 step
        let ladder = AbrLadder.buildLadder(
            startingConfig: tinyConfig,
            deviceTier: 1
        )

        XCTAssertFalse(ladder.steps.isEmpty,
            "Ladder should never be empty — the safety net should create at least one step")

        // The fallback step should use the starting config's values
        XCTAssertEqual(ladder.steps[0].resolution.width, 100,
            "Safety-net step should use the starting config's resolution")
        XCTAssertEqual(ladder.steps[0].fps, 30,
            "Safety-net step should use the starting config's fps")
        XCTAssertEqual(ladder.steps[0].bitrateKbps, 50,
            "Safety-net step should use the starting config's bitrate")
    }
}
