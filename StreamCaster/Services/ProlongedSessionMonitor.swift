// ProlongedSessionMonitor.swift
// StreamCaster
//
// Warns users on older/low-RAM devices about long streaming sessions.
//
// On devices with less than 3 GB of RAM (Tier 1), streaming for a long
// time can cause:
//   - The device to overheat (thermal throttling)
//   - iOS to kill the app due to high memory usage
//   - Degraded stream quality from thermal throttling
//
// After 90 minutes (configurable), we show a friendly reminder to
// consider stopping — unless the device is plugged in and charging,
// which helps with thermals.
//
// Usage:
//   let monitor = ProlongedSessionMonitor()
//   monitor.onProlongedSession = { /* show warning UI */ }
//   monitor.startMonitoring()

import Foundation
import UIKit

/// Monitors how long a streaming session has been running and warns
/// the user if it's been going too long on a lower-end device.
final class ProlongedSessionMonitor {

    // MARK: - Configuration

    /// How long (in seconds) before we warn the user.
    /// Default is 90 minutes (5400 seconds).
    private let warningDuration: TimeInterval

    // MARK: - Callbacks

    /// Called when the session has been running longer than `warningDuration`.
    /// The app should show a non-blocking warning to the user suggesting
    /// they consider stopping the stream.
    var onProlongedSession: (() -> Void)?

    // MARK: - Private State

    /// The timer that fires after `warningDuration` seconds.
    /// We use a regular Timer (not DispatchSourceTimer) for simplicity.
    private var timer: Timer?

    /// Tracks whether we've already shown the warning for this session.
    /// We only warn ONCE per streaming session to avoid nagging.
    private var hasShownWarning = false

    // MARK: - Init

    /// Create a new ProlongedSessionMonitor.
    ///
    /// - Parameter warningDuration: How many seconds before showing the
    ///   warning. Defaults to 90 minutes (5400 seconds).
    init(warningDuration: TimeInterval = 90 * 60) {
        self.warningDuration = warningDuration
    }

    // MARK: - Device Check

    /// Returns `true` if this is an older or low-RAM device (< 3 GB RAM).
    ///
    /// Newer iPhones (iPhone 12+) have 4 GB or more and can handle long
    /// streams without issues. Older devices with less RAM are more likely
    /// to get killed by iOS's memory pressure system (Jetsam).
    ///
    /// `ProcessInfo.processInfo.physicalMemory` returns the total RAM
    /// in bytes. We compare against 3 GB (3 * 1024^3 bytes).
    var isOlderDevice: Bool {
        let threeGigabytes: UInt64 = 3 * 1024 * 1024 * 1024
        return ProcessInfo.processInfo.physicalMemory < threeGigabytes
    }

    // MARK: - Charging Check

    /// Returns `true` if the device is currently plugged in.
    ///
    /// When the device is charging, heat dissipation is better (power
    /// adapter provides power instead of battery), so we skip the warning.
    private var isDeviceCharging: Bool {
        // We need to enable monitoring to read the state.
        // If battery monitoring is already enabled (e.g., by BatteryMonitor),
        // this is a no-op.
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    // MARK: - Start / Stop

    /// Start monitoring the session duration.
    ///
    /// If this is NOT an older device, we skip monitoring entirely —
    /// newer devices can handle long streams just fine.
    ///
    /// The timer fires once after `warningDuration` seconds.
    func startMonitoring() {
        // Reset state for this new session.
        hasShownWarning = false

        // Stop any existing timer from a previous session.
        stopMonitoring()

        // Only monitor older/low-RAM devices. Newer devices don't
        // need this warning.
        guard isOlderDevice else { return }

        // Schedule a timer that fires once after the warning duration.
        // We use RunLoop.main so the timer fires on the main thread,
        // which is safe for UI updates.
        timer = Timer.scheduledTimer(
            withTimeInterval: warningDuration,
            repeats: false
        ) { [weak self] _ in
            // When the timer fires, check conditions and maybe warn.
            self?.handleTimerFired()
        }
    }

    /// Stop monitoring. Call this when the stream stops.
    ///
    /// Invalidating the timer releases it and prevents it from firing.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private Helpers

    /// Called when the warning timer fires.
    ///
    /// Before showing the warning, we check:
    ///   1. Haven't already warned this session
    ///   2. Device is NOT charging (charging = less thermal risk)
    ///
    /// If both conditions pass, we call the `onProlongedSession` callback.
    private func handleTimerFired() {
        // Don't warn twice in the same session.
        guard !hasShownWarning else { return }

        // Don't warn if the device is plugged in — charging helps
        // with thermals and prevents battery drain.
        guard !isDeviceCharging else { return }

        // Show the warning.
        hasShownWarning = true
        onProlongedSession?()
    }
}
