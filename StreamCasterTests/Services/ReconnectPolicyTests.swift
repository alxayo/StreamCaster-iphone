import XCTest
@testable import StreamCaster

// MARK: - ReconnectPolicyTests
/// Tests for ExponentialBackoffReconnectPolicy — the strategy that decides
/// how long to wait between reconnection attempts.
///
/// WHY THESE TESTS MATTER:
/// If the backoff math is wrong, the app could:
/// - Hammer the server with rapid retries (too short delays)
/// - Make users wait forever (delays growing past the cap)
/// - Have all clients retry at the same instant (no jitter)
///
/// The exponential backoff formula is:
///   delay = min(baseDelay × multiplier^(attempt-1), maxDelay) ± jitter
///
/// With defaults: base=3000ms, multiplier=2×, max=60000ms, jitter=±20%

final class ReconnectPolicyTests: XCTestCase {

    // MARK: - Exponential Backoff Sequence

    /// Verify the ideal delay sequence WITHOUT jitter: 3000, 6000, 12000, 24000, 48000, 60000.
    ///
    /// By setting jitterFraction to 0, we can test the pure exponential math.
    /// Each attempt doubles the previous delay until hitting the 60s cap.
    ///
    /// attempt 1: 3000 × 2^0 = 3000ms  (3 seconds)
    /// attempt 2: 3000 × 2^1 = 6000ms  (6 seconds)
    /// attempt 3: 3000 × 2^2 = 12000ms (12 seconds)
    /// attempt 4: 3000 × 2^3 = 24000ms (24 seconds)
    /// attempt 5: 3000 × 2^4 = 48000ms (48 seconds)
    /// attempt 6: 3000 × 2^5 = 96000ms → capped at 60000ms
    func testExponentialBackoffSequence() {
        // Create a policy with NO jitter so delays are deterministic.
        let policy = ExponentialBackoffReconnectPolicy(
            baseDelayMs: 3_000,
            multiplier: 2.0,
            maxDelayMs: 60_000,
            jitterFraction: 0.0,  // No randomness — pure exponential math.
            maxAttempts: 10
        )

        // Expected delay for each attempt number.
        let expectedDelays: [Int64] = [3_000, 6_000, 12_000, 24_000, 48_000, 60_000]

        for (index, expected) in expectedDelays.enumerated() {
            let attempt = index + 1  // Attempts are 1-based (first retry = 1).
            let actual = policy.nextDelayMs(attempt: attempt)

            XCTAssertEqual(actual, expected,
                "Attempt \(attempt): expected \(expected)ms, got \(actual)ms. "
                + "The exponential formula should be: base × 2^(attempt-1), capped at max.")
        }
    }

    /// Verify that the delay NEVER exceeds 60,000ms (60 seconds), even after many attempts.
    ///
    /// Without a cap, attempt 10 would be 3000 × 2^9 = 1,536,000ms (25+ minutes!).
    /// That's way too long to make a user wait. The cap ensures a reasonable maximum.
    func testBackoffCapsAt60Seconds() {
        // No jitter so we can check exact values.
        let policy = ExponentialBackoffReconnectPolicy(
            baseDelayMs: 3_000,
            multiplier: 2.0,
            maxDelayMs: 60_000,
            jitterFraction: 0.0,
            maxAttempts: 20  // Allow many attempts to test the cap.
        )

        // Test a range of high attempt numbers.
        for attempt in 6...20 {
            let delay = policy.nextDelayMs(attempt: attempt)

            XCTAssertLessThanOrEqual(delay, 60_000,
                "Attempt \(attempt): delay \(delay)ms exceeds the 60s cap. "
                + "The policy should clamp delays at maxDelayMs.")
        }
    }

    // MARK: - Jitter Bounds

    /// Verify that jitter stays within ±20% of the base delay.
    ///
    /// Jitter adds randomness so thousands of disconnected clients don't all
    /// retry at the exact same moment (the "thundering herd" problem).
    /// But the jitter must stay within bounds — too much randomness would
    /// make delays unpredictable.
    ///
    /// For attempt 1 with base=3000ms and jitter=±20%:
    ///   minimum = 3000 × 0.8 = 2400ms
    ///   maximum = 3000 × 1.2 = 3600ms
    func testJitterWithinBounds() {
        // Use the DEFAULT jitter fraction (0.20 = ±20%).
        let policy = ExponentialBackoffReconnectPolicy(
            baseDelayMs: 3_000,
            multiplier: 2.0,
            maxDelayMs: 60_000,
            jitterFraction: 0.20,
            maxAttempts: 10
        )

        // For attempt 1, the raw delay (before jitter) is 3000ms.
        // With ±20% jitter: 3000 × 0.8 = 2400, 3000 × 1.2 = 3600.
        let rawDelay: Double = 3_000.0
        let minExpected = rawDelay * 0.8  // 2400ms
        let maxExpected = rawDelay * 1.2  // 3600ms

        // Run 100 samples to catch any out-of-bounds values.
        // (Random tests need multiple iterations to be meaningful.)
        for i in 1...100 {
            let delay = policy.nextDelayMs(attempt: 1)

            XCTAssertGreaterThanOrEqual(delay, Int64(minExpected),
                "Sample \(i): delay \(delay)ms is below the minimum \(Int64(minExpected))ms. "
                + "Jitter should stay within ±\(Int(policy.jitterFraction * 100))%.")
            XCTAssertLessThanOrEqual(delay, Int64(maxExpected),
                "Sample \(i): delay \(delay)ms exceeds the maximum \(Int64(maxExpected))ms. "
                + "Jitter should stay within ±\(Int(policy.jitterFraction * 100))%.")
        }
    }

    /// Verify that jitter is bounded even at the maximum cap.
    ///
    /// When the raw delay is capped at 60,000ms, jitter should still be ±20%
    /// of the CAPPED value (not the uncapped exponential value).
    /// So: min = 60000 × 0.8 = 48000, max = 60000 × 1.2 = 72000.
    func testJitterBoundsAtMaxDelay() {
        let policy = ExponentialBackoffReconnectPolicy(
            baseDelayMs: 3_000,
            multiplier: 2.0,
            maxDelayMs: 60_000,
            jitterFraction: 0.20,
            maxAttempts: 20
        )

        // Attempt 10: raw = 3000 × 2^9 = 1,536,000 → capped at 60,000.
        // Jitter range: 60000 × 0.8 = 48000, 60000 × 1.2 = 72000.
        let cappedDelay: Double = 60_000.0
        let minExpected = cappedDelay * 0.8  // 48000ms
        let maxExpected = cappedDelay * 1.2  // 72000ms

        for i in 1...100 {
            let delay = policy.nextDelayMs(attempt: 10)

            XCTAssertGreaterThanOrEqual(delay, Int64(minExpected),
                "Sample \(i): delay \(delay)ms is below \(Int64(minExpected))ms at max cap.")
            XCTAssertLessThanOrEqual(delay, Int64(maxExpected),
                "Sample \(i): delay \(delay)ms exceeds \(Int64(maxExpected))ms at max cap.")
        }
    }

    // MARK: - Reset

    /// Verify that reset() allows the policy to be reused cleanly.
    ///
    /// After a successful reconnection, the manager calls `reset()` so the
    /// next disconnect starts fresh from the base delay. Even though the
    /// current implementation is stateless (the attempt counter lives in
    /// ConnectionManager), we test reset() to ensure future implementations
    /// that add internal state still work correctly.
    func testResetClearsAttemptCounter() {
        let policy = ExponentialBackoffReconnectPolicy(
            jitterFraction: 0.0  // No jitter for deterministic testing.
        )

        // Simulate several attempts.
        let delayBefore = policy.nextDelayMs(attempt: 5)
        XCTAssertEqual(delayBefore, 48_000,
            "Attempt 5 should return 48000ms (3000 × 2^4).")

        // Reset the policy.
        policy.reset()

        // After reset, asking for attempt 1 should return the base delay.
        // This confirms reset didn't corrupt any internal state.
        let delayAfter = policy.nextDelayMs(attempt: 1)
        XCTAssertEqual(delayAfter, 3_000,
            "After reset, attempt 1 should return the base delay of 3000ms.")
    }

    // MARK: - First Attempt

    /// Verify that the first reconnect attempt uses the base delay (3000ms ± jitter).
    ///
    /// The first retry shouldn't wait too long — the user just lost their
    /// connection and wants it back ASAP. 3 seconds is a good balance between
    /// "try quickly" and "don't spam the server".
    func testFirstAttemptUsesBaseDelay() {
        let policy = ExponentialBackoffReconnectPolicy(
            jitterFraction: 0.0  // No jitter for exact comparison.
        )

        let delay = policy.nextDelayMs(attempt: 1)

        // attempt 1: base × 2^0 = 3000 × 1 = 3000ms
        XCTAssertEqual(delay, 3_000,
            "The first attempt should use the base delay of 3000ms (3 seconds).")
    }

    /// Verify that the first attempt with jitter stays within ±20% of base.
    ///
    /// Even with randomness, the first retry should be close to 3 seconds —
    /// somewhere between 2.4s and 3.6s.
    func testFirstAttemptWithJitterIsNearBase() {
        let policy = ExponentialBackoffReconnectPolicy()  // Default jitter (±20%)

        for _ in 1...50 {
            let delay = policy.nextDelayMs(attempt: 1)

            // 3000 × 0.8 = 2400, 3000 × 1.2 = 3600
            XCTAssertGreaterThanOrEqual(delay, 2_400,
                "First attempt delay \(delay)ms is too low (min 2400ms).")
            XCTAssertLessThanOrEqual(delay, 3_600,
                "First attempt delay \(delay)ms is too high (max 3600ms).")
        }
    }

    // MARK: - shouldRetry

    /// Verify that shouldRetry returns true for attempts within the limit.
    ///
    /// The default maxAttempts is 10, so attempts 1–10 should all return true.
    func testShouldRetryWithinLimit() {
        let policy = ExponentialBackoffReconnectPolicy(maxAttempts: 10)

        for attempt in 1...10 {
            XCTAssertTrue(policy.shouldRetry(attempt: attempt),
                "Attempt \(attempt) should be allowed (maxAttempts is 10).")
        }
    }

    /// Verify that shouldRetry returns false when attempts exceed the limit.
    ///
    /// After exhausting all retries, the manager should stop and tell
    /// the user the connection failed permanently.
    func testShouldRetryExceedsLimit() {
        let policy = ExponentialBackoffReconnectPolicy(maxAttempts: 10)

        XCTAssertFalse(policy.shouldRetry(attempt: 11),
            "Attempt 11 should NOT be allowed when maxAttempts is 10.")
        XCTAssertFalse(policy.shouldRetry(attempt: 100),
            "Attempt 100 should NOT be allowed when maxAttempts is 10.")
    }

    /// Verify that the delay is never negative, even with extreme jitter.
    ///
    /// The policy uses `max(0, ...)` to prevent negative delays.
    /// A negative delay would cause undefined behavior in Task.sleep.
    func testDelayIsNeverNegative() {
        // Use a very small base delay and large jitter to stress-test.
        let policy = ExponentialBackoffReconnectPolicy(
            baseDelayMs: 1,
            multiplier: 2.0,
            maxDelayMs: 60_000,
            jitterFraction: 0.20,
            maxAttempts: 10
        )

        for _ in 1...100 {
            let delay = policy.nextDelayMs(attempt: 1)
            XCTAssertGreaterThanOrEqual(delay, 0,
                "Delay should never be negative, got \(delay)ms.")
        }
    }
}
