// StreamViewModelTests.swift
// StreamCasterTests
//
// Unit tests for StreamViewModel — the bridge between StreamingEngine and SwiftUI.
//
// WHY THESE TESTS MATTER:
// StreamViewModel is what every SwiftUI view reads to decide what to show.
// If its initial state is wrong, users might see "Live" when they haven't
// started streaming, or the Start button might be disabled on first launch.
// These tests catch those regressions early.
//
// TESTING STRATEGY:
// We test the ViewModel's *initial state* — the values it exposes right
// after construction, before any engine events arrive. This is safe to test
// without mocking the engine because the defaults are set inline in the
// ViewModel (not by waiting for Combine events).

import XCTest
@testable import StreamCaster

// All StreamViewModel properties are @MainActor, so the entire test class
// must also run on the main actor. Otherwise Swift concurrency would
// complain about accessing actor-isolated state from a non-isolated context.
@MainActor
final class StreamViewModelTests: XCTestCase {

    // We create a fresh ViewModel for each test so one test's changes
    // never leak into another. This is stored as an implicitly unwrapped
    // optional so setUp() can assign it before each test runs.
    private var viewModel: StreamViewModel!

    // Called automatically before every single test method.
    // Creates a brand-new ViewModel so each test starts from a clean slate.
    override func setUp() {
        super.setUp()
        viewModel = StreamViewModel()
    }

    // Called automatically after every single test method.
    // Releases the ViewModel so memory is freed between tests.
    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Initial State Tests
    // ──────────────────────────────────────────────────────────
    // These tests verify that the ViewModel starts in the correct
    // "ready to stream" state — the first thing users see.

    /// Verify the ViewModel starts in a "ready to stream" state.
    /// This is the first thing users see when they open the app —
    /// every boolean flag and status string must be correct.
    func testInitialStateIsReady() {
        // The stream should NOT be active when the app first opens.
        XCTAssertFalse(viewModel.isStreaming,
                       "Should not be streaming initially — stream hasn't started")

        // We should NOT be in the middle of a connection attempt.
        XCTAssertFalse(viewModel.isConnecting,
                       "Should not be connecting initially — no connection requested")

        // We should NOT be retrying a lost connection.
        XCTAssertFalse(viewModel.isReconnecting,
                       "Should not be reconnecting initially — no connection to lose")

        // The microphone should default to unmuted (audio on).
        XCTAssertFalse(viewModel.isMuted,
                       "Should not be muted initially — users expect audio on by default")

        // The "Start Stream" button should be enabled right away.
        XCTAssertTrue(viewModel.canStartStream,
                      "Should be able to start streaming when idle")

        // The "Stop Stream" button should be disabled (nothing to stop).
        XCTAssertFalse(viewModel.canStopStream,
                       "Should not be able to stop when not streaming")

        // The status label should say "Ready" to reassure the user.
        XCTAssertEqual(viewModel.statusText, "Ready",
                       "Status text should show 'Ready' when idle")

        // The status dot should be gray (neutral, not active).
        XCTAssertEqual(viewModel.statusColor, "gray",
                       "Status color should be gray when idle")
    }

    /// Verify the formatted duration starts at zero.
    /// The duration counter should only start ticking once the stream goes live.
    /// Showing a non-zero value before streaming would confuse users.
    func testInitialDurationIsZero() {
        XCTAssertEqual(viewModel.formattedDuration, "00:00:00",
                       "Duration should be '00:00:00' before streaming starts")
    }

    /// Verify the formatted bitrate starts at zero.
    /// Before any data is sent, the bitrate display should show 0 kbps
    /// so users don't think data is being transmitted.
    func testInitialBitrateIsZero() {
        XCTAssertEqual(viewModel.formattedBitrate, "0 kbps",
                       "Bitrate should be '0 kbps' before streaming starts")
    }

    /// Verify the session snapshot starts in the idle state.
    /// The snapshot is the single source of truth for the whole session —
    /// it must begin as `.idle` to match the engine's initial state.
    func testSessionSnapshotStartsIdle() {
        // Compare with the well-known `.idle` constant defined in StreamSessionSnapshot.
        // This checks transport=idle, media=active, background=foreground, recording=off.
        XCTAssertEqual(viewModel.sessionSnapshot, .idle,
                       "Session snapshot should start as .idle — no active session yet")
    }

    /// Verify that stream stats start with all-zero values.
    /// Before streaming, no data has been sent, so every stat should be zero.
    func testStreamStatsStartsEmpty() {
        let stats = viewModel.streamStats

        // Video bitrate: no video data sent yet → 0 kbps.
        XCTAssertEqual(stats.videoBitrateKbps, 0,
                       "Video bitrate should be 0 before streaming")

        // Audio bitrate: no audio data sent yet → 0 kbps.
        XCTAssertEqual(stats.audioBitrateKbps, 0,
                       "Audio bitrate should be 0 before streaming")

        // FPS: no frames captured yet → 0.
        XCTAssertEqual(stats.fps, 0,
                       "FPS should be 0 before streaming")

        // Dropped frames: nothing has been dropped because nothing was sent.
        XCTAssertEqual(stats.droppedFrames, 0,
                       "Dropped frames should be 0 before streaming")

        // Duration: no time has elapsed in a stream that hasn't started.
        XCTAssertEqual(stats.durationMs, 0,
                       "Duration should be 0 ms before streaming")

        // Resolution string: empty until the encoder is configured.
        XCTAssertEqual(stats.resolution, "",
                       "Resolution should be empty before streaming")

        // Recording flag: local recording hasn't started.
        XCTAssertFalse(stats.isRecording,
                       "Should not be recording before streaming")

        // Thermal level: should default to normal (device is cool).
        XCTAssertEqual(stats.thermalLevel, .normal,
                       "Thermal level should be normal before streaming")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Thermal Warning Tests
    // ──────────────────────────────────────────────────────────

    /// Verify the thermal warning is NOT shown initially.
    /// The warning should only appear when the device is overheating
    /// (thermal level = serious or critical).
    func testThermalWarningNotShownInitially() {
        XCTAssertFalse(viewModel.showThermalWarning,
                       "Thermal warning should not show when device is cool")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Error State Tests
    // ──────────────────────────────────────────────────────────

    /// Verify there is no error message on startup.
    /// Errors should only appear after a failed stream attempt.
    func testNoErrorMessageInitially() {
        XCTAssertNil(viewModel.errorMessage,
                     "Error message should be nil before any stream attempt")
    }

    /// Verify that dismissError() can be called without crashing.
    /// Even when there's no error to dismiss, the method should safely
    /// set errorMessage to nil (a no-op if it's already nil).
    func testDismissErrorSafeWhenNoError() {
        // Call dismissError when there's nothing to dismiss — should not crash.
        viewModel.dismissError()

        XCTAssertNil(viewModel.errorMessage,
                     "Error message should remain nil after dismissing nothing")
    }
}
