import Foundation

// MARK: - ReconnectPolicy
/// Defines the rules for automatically reconnecting when the RTMP connection
/// drops. Different implementations can use different strategies (constant
/// delay, exponential backoff, etc.).
protocol ReconnectPolicy {
    /// Calculate how many milliseconds to wait before the next reconnect attempt.
    /// - Parameter attempt: The attempt number (1 = first retry, 2 = second, …).
    /// - Returns: Delay in milliseconds before retrying.
    func nextDelayMs(attempt: Int) -> Int64

    /// Decide whether we should keep trying to reconnect.
    /// - Parameter attempt: The attempt number (1-based).
    /// - Returns: `true` if we should retry, `false` if we should give up.
    func shouldRetry(attempt: Int) -> Bool

    /// Reset any internal counters. Call this after a successful reconnection
    /// so the next disconnect starts fresh.
    func reset()
}

// MARK: - ExponentialBackoffReconnectPolicy
/// Reconnect strategy that waits longer between each attempt:
///
///   attempt 1 → ~3 s
///   attempt 2 → ~6 s
///   attempt 3 → ~12 s
///   …capped at 60 s
///
/// A random jitter of ±20 % is added so that many disconnected clients
/// don't all hit the server at the exact same moment.
struct ExponentialBackoffReconnectPolicy: ReconnectPolicy {

    /// Base delay for the first retry, in milliseconds (default: 3 000 ms = 3 s).
    let baseDelayMs: Int64

    /// Each subsequent attempt multiplies the delay by this factor (default: 2×).
    let multiplier: Double

    /// The delay will never exceed this value, in milliseconds (default: 60 000 ms = 60 s).
    let maxDelayMs: Int64

    /// Random jitter percentage applied to each delay (default: 0.20 = ±20 %).
    /// This prevents "thundering herd" problems when many clients reconnect.
    let jitterFraction: Double

    /// Maximum number of retry attempts before giving up entirely.
    let maxAttempts: Int

    /// Creates a new exponential-backoff policy with sensible defaults.
    /// - Parameters:
    ///   - baseDelayMs: Starting delay in milliseconds (default: 3000).
    ///   - multiplier: How much to multiply the delay after each attempt (default: 2.0).
    ///   - maxDelayMs: Upper bound on the delay in milliseconds (default: 60000).
    ///   - jitterFraction: Random ± percentage (default: 0.20 for ±20%).
    ///   - maxAttempts: Give up after this many attempts (default: 10).
    init(
        baseDelayMs: Int64 = 3_000,
        multiplier: Double = 2.0,
        maxDelayMs: Int64 = 60_000,
        jitterFraction: Double = 0.20,
        maxAttempts: Int = 10
    ) {
        self.baseDelayMs = baseDelayMs
        self.multiplier = multiplier
        self.maxDelayMs = maxDelayMs
        self.jitterFraction = jitterFraction
        self.maxAttempts = maxAttempts
    }

    func nextDelayMs(attempt: Int) -> Int64 {
        // Calculate raw delay: base × multiplier^(attempt - 1)
        let rawDelay = Double(baseDelayMs) * pow(multiplier, Double(attempt - 1))

        // Cap the delay so it never exceeds the maximum.
        let cappedDelay = min(rawDelay, Double(maxDelayMs))

        // Apply random jitter: ±jitterFraction (e.g., ±20 %).
        let jitterRange = cappedDelay * jitterFraction
        let jitter = Double.random(in: -jitterRange...jitterRange)

        // Make sure we never return a negative delay.
        let finalDelay = max(0, cappedDelay + jitter)
        return Int64(finalDelay)
    }

    func shouldRetry(attempt: Int) -> Bool {
        // Keep retrying as long as we haven't exceeded maxAttempts.
        return attempt <= maxAttempts
    }

    func reset() {
        // This struct is stateless — the attempt counter lives in the caller.
        // Nothing to reset here.
    }
}
