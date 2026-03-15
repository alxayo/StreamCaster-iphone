// ThermalMonitor.swift
// StreamCaster
//
// Watches the device's thermal state and triggers quality degradation
// to prevent overheating during streaming.
//
// iOS THERMAL STATES:
// - .nominal: Everything is cool (literally). No action needed.
// - .fair: Device is getting warm. Show a HUD warning badge.
// - .serious: Device is hot. Step down quality (720p→480p, 30→15fps).
// - .critical: Device is dangerously hot. Stop streaming immediately.
//
// ANTI-OSCILLATION:
// The monitor enforces a minimum 60-second cooldown between thermal
// quality changes. This prevents rapid cycling like:
//   60fps → hot → 15fps → cool → 60fps → hot → 15fps (bad!)
//
// Progressive restoration backoff:
// - First restore attempt: wait 60s
// - Second attempt: wait 120s
// - Third+ attempt: wait 300s
// If a restored config triggers thermal again within the window,
// that config is BLACKLISTED for the rest of the session.
//
// Usage:
//   let monitor = ThermalMonitor()
//   monitor.onThermalWarning = { level in /* show badge */ }
//   monitor.onThermalStepDown = { level in /* reduce quality */ }
//   monitor.onThermalCritical = { /* stop stream */ }
//   monitor.onThermalImproved = { level in /* try restoring quality */ }
//   monitor.startMonitoring()

import Foundation
import Combine

// MARK: - ThermalMonitor

/// Monitors the device's thermal state and notifies the streaming
/// engine when quality should be reduced or restored.
///
/// Conforms to `ThermalMonitorProtocol` so the streaming engine
/// can read the current level and subscribe to changes without
/// knowing the concrete class.
final class ThermalMonitor: ObservableObject, ThermalMonitorProtocol {

    // MARK: - Published State

    /// The current thermal level of the device.
    /// SwiftUI views can observe this to show thermal badges.
    @Published private(set) var currentLevel: ThermalLevel = .normal

    // MARK: - ThermalMonitorProtocol

    /// A Combine publisher that emits a new `ThermalLevel` whenever the
    /// device's thermal state changes. Subscribers (like the streaming
    /// engine) use this to react in real time.
    var thermalLevelPublisher: AnyPublisher<ThermalLevel, Never> {
        $currentLevel.eraseToAnyPublisher()
    }

    // MARK: - Callbacks

    /// Called when the device reaches `.fair` — mildly warm.
    /// The streaming engine should show a warning badge in the HUD.
    var onThermalWarning: ((ThermalLevel) -> Void)?

    /// Called when the device reaches `.serious` — actively hot.
    /// The streaming engine should step down quality (lower resolution,
    /// reduce frame rate) via the EncoderController.
    var onThermalStepDown: ((ThermalLevel) -> Void)?

    /// Called when the device reaches `.critical` — dangerously hot.
    /// The streaming engine should stop the stream immediately to
    /// prevent iOS from killing the app or damaging hardware.
    var onThermalCritical: (() -> Void)?

    /// Called when the thermal state improves (e.g., `.serious` → `.fair`).
    /// The streaming engine can attempt to restore higher quality,
    /// subject to cooldown and blacklist rules in EncoderController.
    var onThermalImproved: ((ThermalLevel) -> Void)?

    // MARK: - Anti-Oscillation Constants

    /// Minimum seconds between thermal quality changes. This prevents
    /// rapid back-and-forth: reduce → cool → restore → hot → reduce…
    static let minimumCooldownSeconds: TimeInterval = 60

    /// How long to wait before each restore attempt. The first restore
    /// waits 60s, the second 120s, and all subsequent attempts wait 300s.
    /// This progressively slows down restore attempts if the device
    /// keeps overheating at higher quality.
    static let restoreBackoffSeconds: [TimeInterval] = [60, 120, 300]

    // MARK: - Private State

    /// Keeps track of our NotificationCenter subscriptions so they are
    /// automatically removed when this object is deallocated.
    private var cancellables = Set<AnyCancellable>()

    /// The timestamp of the last thermal-triggered quality change.
    /// Used to enforce the `minimumCooldownSeconds` cooldown.
    private var lastThermalChangeDate: Date?

    /// How many times we've restored quality in this monitoring session.
    /// Higher counts → longer waits before the next restore attempt.
    private var restoreAttemptCount: Int = 0

    /// Configs (as "WIDTHxHEIGHT@FPS" strings) that caused thermal
    /// escalation after being restored. These are banned for the rest
    /// of the session to stop the device from overheating again.
    private var blacklistedConfigs: Set<String> = []

    // MARK: - Start / Stop

    /// Begin monitoring the device's thermal state.
    /// Call this when the stream starts.
    ///
    /// Steps:
    ///   1. Read the current thermal state immediately.
    ///   2. Register for ongoing thermal state change notifications.
    func startMonitoring() {
        // Reset anti-oscillation state for this monitoring session.
        lastThermalChangeDate = nil
        restoreAttemptCount = 0
        blacklistedConfigs.removeAll()

        // Read the current thermal state right away so we have a
        // starting point (the notification only fires on *changes*).
        let initialState = ProcessInfo.processInfo.thermalState
        currentLevel = mapThermalState(initialState)

        // Listen for thermal state changes from the OS.
        // iOS posts this notification whenever the thermal state changes.
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                self?.handleThermalStateChange()
            }
            .store(in: &cancellables)
    }

    /// Stop monitoring the device's thermal state.
    /// Call this when the stream stops.
    func stopMonitoring() {
        // Remove all notification subscriptions.
        cancellables.removeAll()
    }

    // MARK: - Anti-Oscillation API

    /// Check whether enough time has passed since the last thermal
    /// quality change. Returns `true` if we're still in the cooldown
    /// window and should NOT make another change yet.
    ///
    /// - Returns: `true` if cooldown is active, `false` if safe to change.
    func isCooldownActive() -> Bool {
        guard let lastChange = lastThermalChangeDate else {
            // No previous change — cooldown is not active.
            return false
        }
        let elapsed = Date().timeIntervalSince(lastChange)
        return elapsed < ThermalMonitor.minimumCooldownSeconds
    }

    /// Returns how many seconds remain in the cooldown window,
    /// or 0 if no cooldown is active.
    func cooldownRemainingSeconds() -> Int {
        guard let lastChange = lastThermalChangeDate else { return 0 }
        let elapsed = Date().timeIntervalSince(lastChange)
        let remaining = ThermalMonitor.minimumCooldownSeconds - elapsed
        return max(0, Int(remaining))
    }

    /// Records that a thermal quality change just happened.
    /// This resets the cooldown timer.
    func recordThermalChange() {
        lastThermalChangeDate = Date()
    }

    /// Returns the appropriate restore backoff interval based on how
    /// many restore attempts have been made so far.
    ///
    /// - First attempt:  60 seconds
    /// - Second attempt: 120 seconds
    /// - Third+ attempt: 300 seconds (5 minutes)
    func currentRestoreBackoff() -> TimeInterval {
        let backoffs = ThermalMonitor.restoreBackoffSeconds
        // Use the last value in the array for any attempts beyond
        // what's explicitly listed. e.g., attempt 5 still uses 300s.
        let index = min(restoreAttemptCount, backoffs.count - 1)
        return backoffs[index]
    }

    /// Increment the restore attempt counter. Call this each time
    /// the engine successfully restores quality after a step-down.
    func recordRestoreAttempt() {
        restoreAttemptCount += 1
    }

    /// Add a config string to the blacklist. A blacklisted config
    /// will not be restored to again for the rest of this session.
    ///
    /// - Parameter config: A string like "1280x720@30" identifying
    ///   the resolution and frame rate combination.
    func blacklistConfig(_ config: String) {
        blacklistedConfigs.insert(config)
    }

    /// Check whether a config string is blacklisted.
    ///
    /// - Parameter config: A string like "1280x720@30".
    /// - Returns: `true` if this config caused overheating before.
    func isConfigBlacklisted(_ config: String) -> Bool {
        return blacklistedConfigs.contains(config)
    }

    // MARK: - Private Helpers

    /// Called whenever iOS posts a thermal state change notification.
    /// Reads the new state, maps it to our `ThermalLevel`, and fires
    /// the appropriate callback.
    private func handleThermalStateChange() {
        let newState = ProcessInfo.processInfo.thermalState
        let newLevel = mapThermalState(newState)
        let previousLevel = currentLevel

        // Update the published property (triggers SwiftUI updates).
        currentLevel = newLevel

        // Decide which callback to fire based on the new level.
        switch newLevel {
        case .critical:
            // Device is dangerously hot — stop streaming NOW.
            onThermalCritical?()

        case .serious:
            // Device is hot — reduce quality if we haven't recently.
            onThermalStepDown?(newLevel)

        case .fair:
            // Device is warm. If we came DOWN from a worse state,
            // this is an improvement. If we came UP from normal,
            // this is a warning.
            if previousLevel == .serious || previousLevel == .critical {
                // Thermal is improving — maybe we can restore quality.
                onThermalImproved?(newLevel)
            } else {
                // Thermal is getting worse — warn the user.
                onThermalWarning?(newLevel)
            }

        case .normal:
            // Device cooled down. If we were previously in a degraded
            // state, notify the engine so it can try restoring quality.
            if previousLevel != .normal {
                onThermalImproved?(newLevel)
            }
        }
    }

    /// Convert an iOS `ProcessInfo.ThermalState` to our app's
    /// `ThermalLevel` enum.
    ///
    /// iOS uses `.nominal` while we use `.normal` — same meaning,
    /// just a naming difference to match our app's conventions.
    private func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal:
            return .normal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            // Future-proofing: if Apple adds new thermal states,
            // treat them as "serious" to be safe.
            return .serious
        }
    }
}
