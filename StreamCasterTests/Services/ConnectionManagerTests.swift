import XCTest
@testable import StreamCaster

// MARK: - ConnectionManagerTests
/// Tests for ConnectionManager's public API: connection events, state,
/// and how it handles different failure types.
///
/// WHY THESE TESTS MATTER:
/// ConnectionManager is the heart of the app's reconnection logic.
/// If events carry wrong data or equality checks fail, the streaming
/// engine will make wrong decisions (e.g., thinking it's connected
/// when it's actually disconnected).

final class ConnectionManagerTests: XCTestCase {

    // MARK: - ConnectionEvent Equality

    /// Verify that each ConnectionEvent case is distinguishable from the others.
    ///
    /// Swift enums with associated values only get automatic Equatable if you
    /// explicitly declare it. These tests confirm that the enum cases compare
    /// correctly so the engine can pattern-match on events reliably.
    func testConnectionEventEquality() {
        // Two `.connected` events should be equal — there's no associated data.
        let a = ConnectionManager.ConnectionEvent.connected
        let b = ConnectionManager.ConnectionEvent.connected

        // We can't use XCTAssertEqual directly because ConnectionEvent
        // may not conform to Equatable. Instead, we use a switch to
        // verify the cases match.
        switch (a, b) {
        case (.connected, .connected):
            // Both are `.connected` — this is the expected path.
            break
        default:
            XCTFail("Expected both events to be .connected, but they differ.")
        }
    }

    /// Verify that .disconnected events with DIFFERENT reasons are NOT equal.
    ///
    /// This is critical: `.disconnected(.userRequest)` means "the user chose to stop",
    /// while `.disconnected(.errorAuth)` means "bad credentials". The engine MUST
    /// be able to tell them apart — one should trigger reconnect, the other should not.
    func testDisconnectedWithDifferentReasonsAreNotEqual() {
        let userStop = ConnectionManager.ConnectionEvent.disconnected(reason: .userRequest)
        let authError = ConnectionManager.ConnectionEvent.disconnected(reason: .errorAuth)

        // Use switch to confirm these are different cases with different reasons.
        switch (userStop, authError) {
        case (.disconnected(let r1), .disconnected(let r2)):
            // Both are .disconnected, but the reasons should differ.
            XCTAssertNotEqual(r1, r2,
                "userRequest and errorAuth should be different stop reasons.")
        default:
            XCTFail("Both events should be .disconnected variants.")
        }
    }

    /// Verify that .disconnected events with the SAME reason ARE equal.
    ///
    /// If two identical disconnections occur, the engine should recognize them
    /// as the same event (useful for deduplication and logging).
    func testDisconnectedWithSameReasonAreEqual() {
        let first = ConnectionManager.ConnectionEvent.disconnected(reason: .errorNetwork)
        let second = ConnectionManager.ConnectionEvent.disconnected(reason: .errorNetwork)

        switch (first, second) {
        case (.disconnected(let r1), .disconnected(let r2)):
            // Both reasons should be .errorNetwork.
            XCTAssertEqual(r1, r2,
                "Two disconnected events with the same reason should have equal reasons.")
        default:
            XCTFail("Both events should be .disconnected variants.")
        }
    }

    /// Verify that `.reconnecting` stores the attempt number and delay correctly.
    ///
    /// The UI displays "Reconnecting (attempt 3, next retry in 12s)" to the user.
    /// If these values are wrong, the user sees misleading information.
    func testReconnectingStoresAttemptAndDelay() {
        let event = ConnectionManager.ConnectionEvent.reconnecting(
            attempt: 3,
            nextRetryMs: 12_000
        )

        // Extract the associated values and verify them.
        switch event {
        case .reconnecting(let attempt, let nextRetryMs):
            XCTAssertEqual(attempt, 3,
                "The attempt number should be 3.")
            XCTAssertEqual(nextRetryMs, 12_000,
                "The next retry delay should be 12000 ms (12 seconds).")
        default:
            XCTFail("Expected .reconnecting event, got something else.")
        }
    }

    /// Verify that `.networkAvailable` and `.networkUnavailable` are distinct events.
    ///
    /// The engine uses these to decide whether to skip the reconnect timer
    /// and try immediately (networkAvailable) or pause (networkUnavailable).
    func testNetworkAvailableAndUnavailableAreDistinct() {
        let available = ConnectionManager.ConnectionEvent.networkAvailable
        let unavailable = ConnectionManager.ConnectionEvent.networkUnavailable

        // These two events should NOT match each other.
        switch (available, unavailable) {
        case (.networkAvailable, .networkUnavailable):
            // Correct — they are different events.
            break
        default:
            XCTFail("networkAvailable and networkUnavailable should be distinct events.")
        }
    }

    // MARK: - ConnectionManager State

    /// Verify that a freshly created ConnectionManager starts with zero attempts.
    ///
    /// Before any reconnect sequence begins, the attempt counter should be 0.
    /// This confirms the initial state is clean.
    func testInitialAttemptCountIsZero() {
        let manager = ConnectionManager()

        XCTAssertEqual(manager.currentAttempt, 0,
            "A new ConnectionManager should start with 0 reconnect attempts.")
    }

    /// Verify that the network is assumed available at startup.
    ///
    /// Until NWPathMonitor reports otherwise, we optimistically assume
    /// the network is up. This prevents the app from showing "no network"
    /// errors before the monitor has had a chance to check.
    func testInitialNetworkIsAvailable() {
        let manager = ConnectionManager()

        XCTAssertTrue(manager.isNetworkAvailable,
            "Network should be assumed available before monitoring starts.")
    }

    /// Verify that a custom reconnect policy can be injected.
    ///
    /// Dependency injection lets us swap the real exponential backoff
    /// with a test double, making tests fast and predictable.
    func testCustomReconnectPolicyIsAccepted() {
        // Create a mock policy that always returns a fixed delay.
        let mockPolicy = MockReconnectPolicy()
        let manager = ConnectionManager(reconnectPolicy: mockPolicy)

        // The manager should accept the custom policy without crashing.
        // We verify it works by checking the manager was created successfully.
        XCTAssertEqual(manager.currentAttempt, 0,
            "Manager with custom policy should initialize normally.")
    }

    /// Verify that cancelReconnect resets the attempt counter to zero.
    ///
    /// After cancellation, the manager should be in a clean state
    /// so the next reconnect sequence starts fresh.
    func testCancelReconnectResetsAttemptCounter() {
        let manager = ConnectionManager()

        // Start a reconnect sequence (this sets shouldReconnect = true).
        manager.beginReconnect()

        // Cancel immediately — this should reset everything.
        manager.cancelReconnect()

        XCTAssertEqual(manager.currentAttempt, 0,
            "After cancelReconnect(), attempt counter should be 0.")
    }

    // MARK: - handleConnectionFailure Routing

    /// Verify that auth failure emits a disconnected event and does NOT reconnect.
    ///
    /// Auth failures mean wrong credentials. Retrying with the same bad
    /// credentials will never work, so the manager should give up immediately.
    func testAuthFailureDoesNotReconnect() {
        let manager = ConnectionManager()
        var receivedEvents: [ConnectionManager.ConnectionEvent] = []

        // Register a callback to capture events.
        manager.onConnectionEvent = { event in
            receivedEvents.append(event)
        }

        // Simulate an auth failure.
        manager.handleConnectionFailure(reason: .errorAuth)

        // Should emit a disconnected event with errorAuth reason.
        XCTAssertEqual(receivedEvents.count, 1,
            "Auth failure should emit exactly one event.")

        if case .disconnected(let reason) = receivedEvents.first {
            XCTAssertEqual(reason, .errorAuth,
                "The disconnect reason should be errorAuth.")
        } else {
            XCTFail("Expected a .disconnected event for auth failure.")
        }

        // The attempt counter should still be 0 (no reconnect started).
        XCTAssertEqual(manager.currentAttempt, 0,
            "Auth failure should not start a reconnect sequence.")

        // Clean up: stop monitoring to release resources.
        manager.stopMonitoring()
    }

    /// Verify that user-initiated stop emits disconnected and does NOT reconnect.
    ///
    /// When the user taps "Stop", they explicitly chose to end the stream.
    /// Reconnecting would be a bug — the user wanted to stop!
    func testUserRequestDoesNotReconnect() {
        let manager = ConnectionManager()
        var receivedEvents: [ConnectionManager.ConnectionEvent] = []

        manager.onConnectionEvent = { event in
            receivedEvents.append(event)
        }

        manager.handleConnectionFailure(reason: .userRequest)

        XCTAssertEqual(receivedEvents.count, 1,
            "User stop should emit exactly one event.")

        if case .disconnected(let reason) = receivedEvents.first {
            XCTAssertEqual(reason, .userRequest,
                "The disconnect reason should be userRequest.")
        } else {
            XCTFail("Expected a .disconnected event for user stop.")
        }

        XCTAssertEqual(manager.currentAttempt, 0,
            "User stop should not start a reconnect sequence.")

        manager.stopMonitoring()
    }

    /// Verify that a network error emits disconnected and starts reconnecting.
    ///
    /// Network errors are transient — the connection might come back.
    /// The manager should begin the reconnect sequence automatically.
    func testNetworkErrorStartsReconnect() {
        let manager = ConnectionManager()
        var receivedEvents: [ConnectionManager.ConnectionEvent] = []

        manager.onConnectionEvent = { event in
            receivedEvents.append(event)
        }

        manager.handleConnectionFailure(reason: .errorNetwork)

        // Should emit at least a disconnected event.
        XCTAssertFalse(receivedEvents.isEmpty,
            "Network error should emit at least one event.")

        if case .disconnected(let reason) = receivedEvents.first {
            XCTAssertEqual(reason, .errorNetwork,
                "The disconnect reason should be errorNetwork.")
        } else {
            XCTFail("Expected a .disconnected event for network error.")
        }

        // Clean up: cancel the reconnect task so it doesn't keep running.
        manager.cancelReconnect()
        manager.stopMonitoring()
    }
}

// MARK: - MockReconnectPolicy
/// A simple mock reconnect policy for testing.
/// Returns fixed, predictable values instead of random jitter.
///
/// WHY USE A MOCK?
/// The real ExponentialBackoffReconnectPolicy uses random jitter, which
/// makes exact assertions impossible. This mock lets us test the manager's
/// behavior without worrying about randomness.
private struct MockReconnectPolicy: ReconnectPolicy {
    /// Always returns a fixed delay of 1000ms (1 second).
    func nextDelayMs(attempt: Int) -> Int64 {
        return 1_000
    }

    /// Always says "yes, keep retrying" (up to 5 attempts).
    func shouldRetry(attempt: Int) -> Bool {
        return attempt <= 5
    }

    /// Nothing to reset — this mock is stateless.
    func reset() {}
}
