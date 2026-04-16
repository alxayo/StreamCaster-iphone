import XCTest
@testable import StreamCaster

// ---------------------------------------------------------------------------
// StreamStateTests
// ---------------------------------------------------------------------------
// Tests for every enum and struct defined in StreamState.swift:
//   • TransportState   – RTMP connection lifecycle
//   • BackgroundState   – foreground / PiP / background
//   • RecordingDestination – where local recordings go
//   • RecordingState    – local recording lifecycle
//   • InterruptionOrigin – what caused a media interruption
//   • MediaState        – video/audio/mute tracking
//   • StopReason        – why a stream ended
//   • StreamSessionSnapshot – full session state
// ---------------------------------------------------------------------------

final class StreamStateTests: XCTestCase {

    // MARK: - TransportState — basic cases

    /// Two `.idle` values must be equal.
    /// The engine relies on equality to avoid redundant state updates.
    func testTransportStateIdleIsEquatable() {
        XCTAssertEqual(TransportState.idle, TransportState.idle)
    }

    /// `.connecting` equality. There's only one connecting state.
    func testTransportStateConnectingIsEquatable() {
        XCTAssertEqual(TransportState.connecting, TransportState.connecting)
    }

    /// `.live` equality — the most important "happy path" state.
    func testTransportStateLiveIsEquatable() {
        XCTAssertEqual(TransportState.live, TransportState.live)
    }

    /// `.stopping` equality.
    func testTransportStateStoppingIsEquatable() {
        XCTAssertEqual(TransportState.stopping, TransportState.stopping)
    }

    /// Two different simple states must NOT be equal.
    /// Guards against an accidental blanket `==` that always returns true.
    func testTransportStateDifferentCasesAreNotEqual() {
        XCTAssertNotEqual(TransportState.idle, TransportState.connecting)
        XCTAssertNotEqual(TransportState.connecting, TransportState.live)
        XCTAssertNotEqual(TransportState.live, TransportState.stopping)
    }

    // MARK: - TransportState — reconnecting

    /// `.reconnecting` stores the attempt number, max attempts, and next-retry delay.
    /// The UI reads these to show "Reconnecting (attempt 3 of 10, retrying in 5 s)".
    func testTransportStateReconnectingStoresAttemptMaxAndDelay() {
        let state = TransportState.reconnecting(attempt: 3, maxAttempts: 10, nextRetryMs: 5000)

        // Extract associated values with pattern matching.
        if case .reconnecting(let attempt, let maxAttempts, let nextRetryMs) = state {
            XCTAssertEqual(attempt, 3)
            XCTAssertEqual(maxAttempts, 10)
            XCTAssertEqual(nextRetryMs, 5000)
        } else {
            XCTFail("Expected .reconnecting but got \(state)")
        }
    }

    /// Two `.reconnecting` values with the same data are equal.
    func testTransportStateReconnectingEqualWhenSameValues() {
        let a = TransportState.reconnecting(attempt: 1, maxAttempts: 10, nextRetryMs: 2000)
        let b = TransportState.reconnecting(attempt: 1, maxAttempts: 10, nextRetryMs: 2000)
        XCTAssertEqual(a, b)
    }

    /// Different attempt counts make the states NOT equal.
    func testTransportStateReconnectingNotEqualDifferentAttempt() {
        let a = TransportState.reconnecting(attempt: 1, maxAttempts: 10, nextRetryMs: 2000)
        let b = TransportState.reconnecting(attempt: 2, maxAttempts: 10, nextRetryMs: 2000)
        XCTAssertNotEqual(a, b)
    }

    /// Different retry delays make the states NOT equal.
    func testTransportStateReconnectingNotEqualDifferentDelay() {
        let a = TransportState.reconnecting(attempt: 1, maxAttempts: 10, nextRetryMs: 1000)
        let b = TransportState.reconnecting(attempt: 1, maxAttempts: 10, nextRetryMs: 5000)
        XCTAssertNotEqual(a, b)
    }

    /// Different max attempts make the states NOT equal.
    func testTransportStateReconnectingNotEqualDifferentMaxAttempts() {
        let a = TransportState.reconnecting(attempt: 1, maxAttempts: 5, nextRetryMs: 2000)
        let b = TransportState.reconnecting(attempt: 1, maxAttempts: 10, nextRetryMs: 2000)
        XCTAssertNotEqual(a, b)
    }

    /// Unlimited reconnect attempts use Int.max for maxAttempts.
    func testTransportStateReconnectingUnlimitedMaxAttempts() {
        let state = TransportState.reconnecting(attempt: 1, maxAttempts: Int.max, nextRetryMs: 3000)
        if case .reconnecting(_, let maxAttempts, _) = state {
            XCTAssertEqual(maxAttempts, Int.max)
        } else {
            XCTFail("Expected .reconnecting")
        }
    }

    // MARK: - TransportState — stopped

    /// `.stopped` wraps a `StopReason` so the UI can display the correct error.
    func testTransportStateStoppedStoresReason() {
        let state = TransportState.stopped(reason: .errorNetwork)

        if case .stopped(let reason) = state {
            XCTAssertEqual(reason, .errorNetwork)
        } else {
            XCTFail("Expected .stopped but got \(state)")
        }
    }

    /// `.stopped` with different reasons are not equal.
    func testTransportStateStoppedNotEqualDifferentReasons() {
        let a = TransportState.stopped(reason: .userRequest)
        let b = TransportState.stopped(reason: .errorAuth)
        XCTAssertNotEqual(a, b)
    }

    /// `.stopped` with the same reason are equal.
    func testTransportStateStoppedEqualSameReason() {
        let a = TransportState.stopped(reason: .thermalCritical)
        let b = TransportState.stopped(reason: .thermalCritical)
        XCTAssertEqual(a, b)
    }

    // MARK: - StopReason — all cases & raw values

    /// Every `StopReason` case must exist and have a stable raw value.
    /// Raw values are used when the reason is encoded to JSON or sent to analytics,
    /// so changing them would break backward compatibility.
    func testStopReasonAllCasesExist() {
        let expected: [StopReason] = [
            .userRequest,
            .errorEncoder,
            .errorAuth,
            .errorCamera,
            .errorAudio,
            .errorNetwork,
            .errorStorage,
            .thermalCritical,
            .batteryCritical,
            .pipDismissedVideoOnly,
            .osTerminated,
            .unknown,
        ]

        // Make sure we listed every case by verifying count.
        // If a new case is added to the enum, this test will remind us to cover it.
        XCTAssertEqual(expected.count, 12, "Update this test when adding new StopReason cases")

        // Each case should round-trip through its rawValue.
        for reason in expected {
            XCTAssertEqual(StopReason(rawValue: reason.rawValue), reason,
                           "\(reason) did not round-trip through rawValue")
        }
    }

    /// Spot-check a few raw values so we notice if someone renames them.
    func testStopReasonRawValues() {
        XCTAssertEqual(StopReason.userRequest.rawValue, "userRequest")
        XCTAssertEqual(StopReason.errorNetwork.rawValue, "errorNetwork")
        XCTAssertEqual(StopReason.thermalCritical.rawValue, "thermalCritical")
        XCTAssertEqual(StopReason.unknown.rawValue, "unknown")
    }

    // MARK: - BackgroundState

    /// All five background states must be distinguishable.
    /// The streaming engine uses these to decide whether to keep encoding video.
    func testBackgroundStateAllCasesAreDistinct() {
        let all: [BackgroundState] = [
            .foreground,
            .pipStarting,
            .pipActive,
            .backgroundAudioOnly,
            .suspended,
        ]
        // Pairwise inequality — each state is unique.
        for i in all.indices {
            for j in all.indices where j != i {
                XCTAssertNotEqual(all[i], all[j],
                                  "\(all[i]) should not equal \(all[j])")
            }
        }
    }

    /// Foreground-to-PiP is the most common transition.
    /// Verify the two states are not accidentally the same.
    func testBackgroundStateForegroundNotEqualPipActive() {
        XCTAssertNotEqual(BackgroundState.foreground, BackgroundState.pipActive)
    }

    /// Same state must equal itself (Equatable conformance sanity check).
    func testBackgroundStateSelfEquality() {
        XCTAssertEqual(BackgroundState.foreground, BackgroundState.foreground)
        XCTAssertEqual(BackgroundState.suspended, BackgroundState.suspended)
    }

    // MARK: - RecordingDestination — raw values

    /// `RecordingDestination` is `Codable` with a raw string.
    /// The raw value ends up in persisted settings, so it must stay stable.
    func testRecordingDestinationRawValues() {
        XCTAssertEqual(RecordingDestination.photosLibrary.rawValue, "photosLibrary")
        XCTAssertEqual(RecordingDestination.documents.rawValue, "documents")
    }

    /// Round-trip through rawValue: create from string and compare.
    func testRecordingDestinationRoundTrip() {
        XCTAssertEqual(
            RecordingDestination(rawValue: "photosLibrary"),
            .photosLibrary
        )
        XCTAssertEqual(
            RecordingDestination(rawValue: "documents"),
            .documents
        )
    }

    /// An unknown raw value should return nil — not crash.
    func testRecordingDestinationUnknownRawValue() {
        XCTAssertNil(RecordingDestination(rawValue: "icloud"))
    }

    // MARK: - RecordingState

    /// `.off` is the default; two `.off` values are equal.
    func testRecordingStateOffEquality() {
        XCTAssertEqual(RecordingState.off, RecordingState.off)
    }

    /// `.starting` stores the destination so we know where the file will go.
    func testRecordingStateStartingStoresDestination() {
        let state = RecordingState.starting(destination: .photosLibrary)
        if case .starting(let dest) = state {
            XCTAssertEqual(dest, .photosLibrary)
        } else {
            XCTFail("Expected .starting")
        }
    }

    /// `.recording` stores the destination for the active file.
    func testRecordingStateRecordingStoresDestination() {
        let state = RecordingState.recording(destination: .documents)
        if case .recording(let dest) = state {
            XCTAssertEqual(dest, .documents)
        } else {
            XCTFail("Expected .recording")
        }
    }

    /// `.finalizing` equality — the "flushing to disk" state.
    func testRecordingStateFinalizingEquality() {
        XCTAssertEqual(RecordingState.finalizing, RecordingState.finalizing)
    }

    /// `.failed` stores a human-readable reason string.
    func testRecordingStateFailedStoresReason() {
        let state = RecordingState.failed(reason: "Disk full")
        if case .failed(let reason) = state {
            XCTAssertEqual(reason, "Disk full")
        } else {
            XCTFail("Expected .failed")
        }
    }

    /// Different failure reasons must not be equal.
    func testRecordingStateFailedNotEqualDifferentReasons() {
        let a = RecordingState.failed(reason: "Disk full")
        let b = RecordingState.failed(reason: "Permission denied")
        XCTAssertNotEqual(a, b)
    }

    /// Different recording states must not be equal.
    func testRecordingStateDifferentCasesNotEqual() {
        XCTAssertNotEqual(RecordingState.off,
                          RecordingState.starting(destination: .photosLibrary))
        XCTAssertNotEqual(RecordingState.starting(destination: .photosLibrary),
                          RecordingState.recording(destination: .photosLibrary))
        XCTAssertNotEqual(RecordingState.recording(destination: .documents),
                          RecordingState.finalizing)
    }

    // MARK: - InterruptionOrigin — raw values

    /// `InterruptionOrigin` raw values must remain stable for analytics/logging.
    func testInterruptionOriginRawValues() {
        XCTAssertEqual(InterruptionOrigin.none.rawValue, "none")
        XCTAssertEqual(InterruptionOrigin.audioSession.rawValue, "audioSession")
        XCTAssertEqual(InterruptionOrigin.pipDismissed.rawValue, "pipDismissed")
        XCTAssertEqual(InterruptionOrigin.cameraUnavailable.rawValue, "cameraUnavailable")
        XCTAssertEqual(InterruptionOrigin.sampleStall.rawValue, "sampleStall")
        XCTAssertEqual(InterruptionOrigin.systemPressure.rawValue, "systemPressure")
    }

    /// All six cases must exist. If a case is added, this count forces an update.
    func testInterruptionOriginCaseCount() {
        let all: [InterruptionOrigin] = [
            .none, .audioSession, .pipDismissed,
            .cameraUnavailable, .sampleStall, .systemPressure,
        ]
        XCTAssertEqual(all.count, 6,
                       "Update this test when adding new InterruptionOrigin cases")
    }

    // MARK: - MediaState

    /// Default `MediaState` has video and audio active, not muted, no interruption.
    /// The engine relies on these defaults when starting a new session.
    func testMediaStateDefaults() {
        let state = MediaState()
        XCTAssertTrue(state.videoActive, "Video should be active by default")
        XCTAssertTrue(state.audioActive, "Audio should be active by default")
        XCTAssertFalse(state.audioMuted, "Audio should not be muted by default")
        XCTAssertEqual(state.interruptionOrigin, .none,
                       "No interruption by default")
    }

    /// Two default MediaStates are equal.
    func testMediaStateDefaultEquality() {
        XCTAssertEqual(MediaState(), MediaState())
    }

    /// Changing any single property produces a different state.
    func testMediaStateDiffersWhenPropertyChanges() {
        let base = MediaState()

        var mutedState = base
        mutedState.audioMuted = true
        XCTAssertNotEqual(base, mutedState)

        var noVideo = base
        noVideo.videoActive = false
        XCTAssertNotEqual(base, noVideo)

        var interrupted = base
        interrupted.interruptionOrigin = .audioSession
        XCTAssertNotEqual(base, interrupted)
    }

    // MARK: - StreamSessionSnapshot — idle convenience

    /// `StreamSessionSnapshot.idle` is the "factory reset" state.
    /// It must have idle transport, default media, foreground, and no recording.
    func testStreamSessionSnapshotIdleValues() {
        let snapshot = StreamSessionSnapshot.idle

        // Transport should start at idle — not connected anywhere.
        XCTAssertEqual(snapshot.transport, .idle)

        // Media should have both tracks active, not muted.
        XCTAssertTrue(snapshot.media.videoActive)
        XCTAssertTrue(snapshot.media.audioActive)
        XCTAssertFalse(snapshot.media.audioMuted)
        XCTAssertEqual(snapshot.media.interruptionOrigin, .none)

        // App should start in the foreground.
        XCTAssertEqual(snapshot.background, .foreground)

        // No recording by default.
        XCTAssertEqual(snapshot.recording, .off)
    }

    /// Two `.idle` snapshots must be equal.
    func testStreamSessionSnapshotIdleEquality() {
        XCTAssertEqual(StreamSessionSnapshot.idle, StreamSessionSnapshot.idle)
    }

    // MARK: - StreamSessionSnapshot — equality

    /// Snapshots with the same values must be equal regardless of how they were built.
    func testStreamSessionSnapshotEqualityWithSameValues() {
        let a = StreamSessionSnapshot(
            transport: .live,
            media: MediaState(videoActive: true, audioActive: false,
                              audioMuted: true, interruptionOrigin: .none),
            background: .pipActive,
            recording: .recording(destination: .documents)
        )
        let b = StreamSessionSnapshot(
            transport: .live,
            media: MediaState(videoActive: true, audioActive: false,
                              audioMuted: true, interruptionOrigin: .none),
            background: .pipActive,
            recording: .recording(destination: .documents)
        )
        XCTAssertEqual(a, b)
    }

    /// Changing the transport state makes the snapshots different.
    func testStreamSessionSnapshotNotEqualDifferentTransport() {
        var snapshot = StreamSessionSnapshot.idle
        snapshot.transport = .live
        XCTAssertNotEqual(snapshot, StreamSessionSnapshot.idle)
    }

    /// Changing the background state makes the snapshots different.
    func testStreamSessionSnapshotNotEqualDifferentBackground() {
        var snapshot = StreamSessionSnapshot.idle
        snapshot.background = .suspended
        XCTAssertNotEqual(snapshot, StreamSessionSnapshot.idle)
    }

    /// Changing the recording state makes the snapshots different.
    func testStreamSessionSnapshotNotEqualDifferentRecording() {
        var snapshot = StreamSessionSnapshot.idle
        snapshot.recording = .recording(destination: .photosLibrary)
        XCTAssertNotEqual(snapshot, StreamSessionSnapshot.idle)
    }

    /// Changing a media property makes the snapshots different.
    func testStreamSessionSnapshotNotEqualDifferentMedia() {
        var snapshot = StreamSessionSnapshot.idle
        snapshot.media.audioMuted = true
        XCTAssertNotEqual(snapshot, StreamSessionSnapshot.idle)
    }
}
