import Foundation
import Network
import Combine

// MARK: - ConnectionManager
/// ConnectionManager handles the RTMP connection lifecycle:
/// - Connecting to the RTMP server
/// - Detecting network drops via NWPathMonitor
/// - Auto-reconnecting with exponential backoff + jitter
///
/// IMPORTANT: ConnectionManager does NOT own the stream state.
/// It submits "intents" (requests) via `onConnectionEvent`, and the
/// StreamingEngine — the single source of truth — decides how to
/// act on them.
///
/// Reconnect behavior:
/// - On network drop: start exponential backoff (3s, 6s, 12s, ..., 60s cap)
/// - On NWPathMonitor "network available": try immediately (skip timer)
/// - On auth failure: NEVER retry (wrong credentials won't fix themselves)
/// - On user stop: cancel ALL pending reconnects immediately
final class ConnectionManager {

    // MARK: - Connection Events

    /// Events that ConnectionManager emits to tell the engine what happened.
    /// The engine listens for these and updates its own state accordingly.
    enum ConnectionEvent {
        /// Successfully connected to the RTMP server.
        case connected

        /// Disconnected from the RTMP server.
        /// `reason` explains why (user request, network error, auth failure, etc.).
        case disconnected(reason: StopReason)

        /// Currently trying to reconnect.
        /// `attempt` is which retry we're on (1, 2, 3…).
        /// `nextRetryMs` is how long we'll wait before the next try.
        case reconnecting(attempt: Int, nextRetryMs: Int64)

        /// Network connectivity has been restored (Wi-Fi/cellular is back).
        case networkAvailable

        /// Network connectivity was lost (no Wi-Fi or cellular).
        case networkUnavailable
    }

    // MARK: - Properties

    /// The reconnect policy decides how long to wait between retries.
    /// Default is exponential backoff: 3s → 6s → 12s → … capped at 60s.
    private let reconnectPolicy: ReconnectPolicy

    /// NWPathMonitor watches for network connectivity changes at the OS level.
    /// It tells us instantly when Wi-Fi or cellular goes up or down.
    private let pathMonitor: NWPathMonitor

    /// A dedicated background queue for the path monitor.
    /// Network callbacks shouldn't block the main thread.
    private let monitorQueue: DispatchQueue

    /// Whether the device currently has a network connection.
    /// @Published so Combine subscribers can react to changes.
    @Published private(set) var isNetworkAvailable: Bool = true

    /// How many reconnect attempts we've made so far.
    /// 0 means we're not in a reconnect sequence.
    private(set) var currentAttempt: Int = 0

    /// The async Task that manages the reconnect delay loop.
    /// We keep a reference so we can cancel it when the user stops streaming
    /// or when the network comes back (so we can retry immediately).
    private var reconnectTask: Task<Void, Never>?

    /// Whether we're currently in "reconnect mode".
    /// Set to `true` when a connection drops, `false` when we give up or succeed.
    private var shouldReconnect: Bool = false

    /// A serial queue to protect reconnect state from race conditions.
    /// All reads/writes to `shouldReconnect`, `currentAttempt`, and
    /// `reconnectTask` happen on this queue.
    private let stateQueue = DispatchQueue(label: "com.port80.app.connectionManager.state")

    /// Callback the engine registers to receive connection events.
    /// ConnectionManager calls this whenever something interesting happens
    /// (connected, disconnected, reconnecting, network change).
    var onConnectionEvent: ((ConnectionEvent) -> Void)?

    // MARK: - Init

    /// Create a new ConnectionManager.
    ///
    /// - Parameter reconnectPolicy: The strategy for timing retries.
    ///   Defaults to exponential backoff (3s, 6s, 12s, …, 60s cap with ±20% jitter).
    init(reconnectPolicy: ReconnectPolicy = ExponentialBackoffReconnectPolicy()) {
        self.reconnectPolicy = reconnectPolicy
        self.pathMonitor = NWPathMonitor()
        self.monitorQueue = DispatchQueue(
            label: "com.port80.app.connectionManager.networkMonitor",
            qos: .utility
        )
    }

    // MARK: - Network Monitoring

    /// Start watching for network connectivity changes.
    ///
    /// NWPathMonitor runs on a background queue and calls our handler
    /// every time the network path changes (e.g., Wi-Fi drops, cellular
    /// becomes available, airplane mode toggled).
    func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            // Check if the device has ANY network connection.
            let available = path.status == .satisfied

            // Update our published property so subscribers know.
            self.isNetworkAvailable = available

            if available {
                // Network just came back! Tell the engine.
                self.onConnectionEvent?(.networkAvailable)

                // If we were waiting to reconnect, skip the timer and try NOW.
                // The idea: why wait 12 seconds if the network just came back?
                self.handleNetworkRestored()
            } else {
                // Network went down. Tell the engine.
                self.onConnectionEvent?(.networkUnavailable)
            }
        }

        // Start the monitor on our background queue.
        pathMonitor.start(queue: monitorQueue)
    }

    /// Stop watching for network changes and cancel any pending reconnects.
    ///
    /// Call this when the app is shutting down or the engine is being
    /// torn down. After calling this, no more events will be emitted.
    func stopMonitoring() {
        pathMonitor.cancel()
        cancelReconnect()
    }

    // MARK: - Reconnect Lifecycle

    /// Begin the reconnect sequence after a connection loss.
    ///
    /// This starts a loop that:
    ///   1. Calculates the delay from the reconnect policy
    ///   2. Waits that long (using Task.sleep)
    ///   3. Notifies the engine to try connecting again
    ///   4. Repeats until success, max attempts, or cancellation
    ///
    /// If a reconnect sequence is already running, this method does nothing
    /// (we don't want to start a second parallel sequence).
    func beginReconnect() {
        stateQueue.sync {
            // Don't start a new sequence if one is already running.
            guard !self.shouldReconnect else { return }

            // Enter reconnect mode.
            self.shouldReconnect = true
            self.currentAttempt = 0

            // Reset the policy's internal state (if any) so delays start fresh.
            self.reconnectPolicy.reset()
        }

        // Launch the reconnect loop in an async Task.
        scheduleNextAttempt()
    }

    /// Cancel all pending reconnect attempts.
    ///
    /// Called when:
    /// - The user taps "Stop" (they don't want to reconnect)
    /// - Auth fails (retrying won't help — credentials are wrong)
    /// - We successfully reconnect (no more retries needed)
    func cancelReconnect() {
        stateQueue.sync {
            self.shouldReconnect = false
            self.currentAttempt = 0
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.reconnectPolicy.reset()
        }
    }

    /// Decide what to do when a connection failure occurs.
    ///
    /// Different failure types get different treatment:
    /// - Auth failure → stop immediately, never retry
    /// - User stop → cancel everything
    /// - Network error → start reconnecting
    /// - Other errors → start reconnecting
    ///
    /// - Parameter reason: Why the connection failed.
    func handleConnectionFailure(reason: StopReason) {
        switch reason {
        case .errorAuth:
            // Auth failures mean wrong credentials. Retrying with the same
            // bad credentials will never work, so we stop immediately.
            cancelReconnect()
            onConnectionEvent?(.disconnected(reason: .errorAuth))

        case .userRequest:
            // The user explicitly stopped the stream. Don't try to
            // reconnect — they wanted to stop!
            cancelReconnect()
            onConnectionEvent?(.disconnected(reason: .userRequest))

        case .errorNetwork:
            // Network dropped. This is the most common case for reconnecting.
            onConnectionEvent?(.disconnected(reason: .errorNetwork))
            beginReconnect()

        default:
            // For any other error (encoder, camera, etc.), attempt to reconnect.
            // The engine can decide to override this if needed.
            onConnectionEvent?(.disconnected(reason: reason))
            beginReconnect()
        }
    }

    // MARK: - Private Helpers

    /// Schedule the next reconnect attempt in an async Task.
    ///
    /// The Task sleeps for the delay calculated by the reconnect policy,
    /// then emits a `.reconnecting` event so the engine knows to try again.
    /// If the Task is cancelled (user stopped, or network came back),
    /// it exits gracefully.
    private func scheduleNextAttempt() {
        reconnectTask = Task { [weak self] in
            guard let self = self else { return }

            while true {
                // Check if we should still be reconnecting.
                let shouldContinue: Bool = self.stateQueue.sync {
                    return self.shouldReconnect
                }
                guard shouldContinue else { return }

                // Bump the attempt counter.
                let attempt: Int = self.stateQueue.sync {
                    self.currentAttempt += 1
                    return self.currentAttempt
                }

                // Ask the policy if we should keep trying.
                guard self.reconnectPolicy.shouldRetry(attempt: attempt) else {
                    // We've exhausted all retry attempts. Give up.
                    self.onConnectionEvent?(.disconnected(reason: .errorNetwork))
                    self.stateQueue.sync {
                        self.shouldReconnect = false
                        self.currentAttempt = 0
                    }
                    return
                }

                // Calculate how long to wait before the next attempt.
                let delayMs = self.reconnectPolicy.nextDelayMs(attempt: attempt)

                // Tell the engine we're about to reconnect (so it can update the UI).
                self.onConnectionEvent?(.reconnecting(attempt: attempt, nextRetryMs: delayMs))

                // Wait for the calculated delay.
                // Task.sleep is cancellation-aware: if the task is cancelled
                // while sleeping, it throws CancellationError and we exit.
                let delayNanoseconds = UInt64(delayMs) * 1_000_000
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    // Task was cancelled — either the user stopped or
                    // the network came back and we're retrying immediately.
                    return
                }

                // After sleeping, check again if we were cancelled.
                if Task.isCancelled { return }

                // Notify the engine that it's time to attempt a reconnection.
                // The engine will call connect() on the encoder bridge.
                self.onConnectionEvent?(.connected)
            }
        }
    }

    /// Called when NWPathMonitor detects that the network is back.
    ///
    /// If we're in the middle of a reconnect sequence (waiting for a timer),
    /// cancel the current wait and try immediately. No point waiting 12
    /// seconds if the network just came back!
    private func handleNetworkRestored() {
        let isReconnecting: Bool = stateQueue.sync {
            return self.shouldReconnect
        }

        guard isReconnecting else { return }

        // Cancel the current sleep timer.
        stateQueue.sync {
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
        }

        // Try immediately by scheduling a new attempt right away.
        // The attempt counter is NOT reset — we continue counting
        // from where we left off (so we still respect maxAttempts).
        scheduleNextAttempt()
    }

    // MARK: - Transport Security

    /// Validate transport security before connecting to an RTMP server.
    ///
    /// This checks whether the profile's URL and credentials are safe
    /// to use together. If credentials would be sent over plaintext
    /// (rtmp:// instead of rtmps://), the connection is blocked and
    /// a `.disconnected(.errorAuth)` event is emitted.
    ///
    /// - Parameter profile: The endpoint profile the user wants to connect to.
    /// - Returns: The `ValidationResult`. Callers should check this before
    ///   proceeding with the actual RTMP connection.
    func validateTransportSecurity(
        profile: EndpointProfile
    ) -> TransportSecurityValidator.ValidationResult {
        let result = TransportSecurityValidator.validate(profile: profile)

        switch result {
        case .blockedPlaintextWithCredentials:
            // Hard-block: credentials over plaintext is never allowed.
            // Emit an auth error so the engine knows the connection was rejected.
            cancelReconnect()
            onConnectionEvent?(.disconnected(reason: .errorAuth))

        case .warningPlaintext:
            // Plain RTMP without credentials — the caller decides whether
            // to proceed or show a warning to the user.
            break

        case .allowed:
            // RTMPS — all good, nothing to do here.
            break
        }

        return result
    }

    // MARK: - Cleanup

    deinit {
        // Make sure we clean up the network monitor and cancel any
        // pending reconnect tasks when this object is deallocated.
        stopMonitoring()
    }
}
