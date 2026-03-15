// BatteryMonitor.swift
// StreamCaster
//
// Watches the device's battery level and alerts the app when it gets
// dangerously low during streaming.
//
// Battery thresholds:
//   - Warning (default 5%): Show a warning to the user
//   - Critical (≤ 2%): Auto-stop the stream and finalize any recording
//     to prevent data loss from unexpected shutdown
//
// The warning threshold is configurable in Settings.
//
// Usage:
//   let monitor = BatteryMonitor(settingsRepository: repo)
//   monitor.onLowBatteryWarning = { /* show warning UI */ }
//   monitor.onCriticalBattery = { /* stop stream, save recording */ }
//   monitor.startMonitoring()

import UIKit
import Combine
import Foundation

// MARK: - BatteryMonitor

/// Monitors the device's battery level and charging state, raising
/// callbacks when the battery drops to dangerous levels.
///
/// This is an `ObservableObject` so SwiftUI views can display
/// the current battery level and charging indicator.
final class BatteryMonitor: ObservableObject {

    // MARK: - Published State

    /// The current battery level as a float from 0.0 (empty) to 1.0 (full).
    /// Updated automatically whenever iOS reports a change.
    @Published private(set) var batteryLevel: Float = 1.0

    /// `true` when the device is plugged in and charging (or fully charged).
    @Published private(set) var isCharging: Bool = false

    // MARK: - Callbacks

    /// Called when the battery drops to or below the warning threshold
    /// (default 5%, configurable in Settings). The streaming engine
    /// should show a warning to the user.
    var onLowBatteryWarning: (() -> Void)?

    /// Called when the battery drops to the critical level (≤ 2%).
    /// The streaming engine should auto-stop the stream and finalize
    /// any local recording to prevent data loss.
    var onCriticalBattery: (() -> Void)?

    // MARK: - Constants

    /// The critical battery threshold (2%). Below this level, the device
    /// could shut down at any moment, so we force-stop the stream.
    /// This value is NOT configurable — it's a safety net.
    private static let criticalThresholdPercent: Float = 2.0

    // MARK: - Dependencies

    /// Repository for reading user settings (specifically, the low-battery
    /// warning threshold that the user configured in the Settings screen).
    private let settingsRepository: SettingsRepository

    // MARK: - Private State

    /// Keeps track of our NotificationCenter subscriptions so they are
    /// automatically removed when this object is deallocated.
    private var cancellables = Set<AnyCancellable>()

    /// Tracks whether we already fired the warning callback for the
    /// current discharge cycle. We reset this when the battery starts
    /// charging again, so the warning can fire again on the next discharge.
    private var hasWarned: Bool = false

    /// Tracks whether we already fired the critical callback.
    /// Same reset logic as `hasWarned`.
    private var hasFiredCritical: Bool = false

    // MARK: - Init

    /// Create a new BatteryMonitor.
    ///
    /// - Parameter settingsRepository: Used to read the user's configured
    ///   low-battery warning threshold (e.g., 5%).
    init(settingsRepository: SettingsRepository) {
        self.settingsRepository = settingsRepository
    }

    // MARK: - Start / Stop

    /// Begin monitoring the battery. Call this when the stream starts.
    ///
    /// Steps:
    ///   1. Tell iOS we want battery updates (it's off by default to save power).
    ///   2. Read the current level and state immediately.
    ///   3. Register for ongoing notifications about level and state changes.
    func startMonitoring() {
        // Enable battery monitoring — iOS doesn't track it by default
        // because it uses a tiny bit of extra energy.
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Read the current values right away so we have a starting point.
        updateBatteryLevel()
        updateChargingState()

        // Reset warning flags for this monitoring session.
        hasWarned = false
        hasFiredCritical = false

        // Listen for battery LEVEL changes (e.g., 50% → 49%).
        NotificationCenter.default
            .publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .sink { [weak self] _ in
                self?.updateBatteryLevel()
                self?.checkThresholds()
            }
            .store(in: &cancellables)

        // Listen for battery STATE changes (e.g., unplugged → charging).
        NotificationCenter.default
            .publisher(for: UIDevice.batteryStateDidChangeNotification)
            .sink { [weak self] _ in
                self?.updateChargingState()
            }
            .store(in: &cancellables)
    }

    /// Stop monitoring the battery. Call this when the stream stops.
    ///
    /// Disabling battery monitoring saves a small amount of energy
    /// when we don't need the updates.
    func stopMonitoring() {
        // Remove all notification subscriptions.
        cancellables.removeAll()

        // Tell iOS we no longer need battery updates.
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    // MARK: - Private Helpers

    /// Read the current battery level from the device and update
    /// our published property.
    ///
    /// `UIDevice.current.batteryLevel` returns a float from 0.0 to 1.0,
    /// or -1.0 if monitoring is disabled. We clamp to 0.0 in that case.
    private func updateBatteryLevel() {
        let level = UIDevice.current.batteryLevel
        // -1.0 means "unknown" (monitoring not enabled). Treat as 0.
        batteryLevel = max(level, 0.0)
    }

    /// Read the current charging state from the device and update
    /// our published property.
    ///
    /// `UIDevice.current.batteryState` can be:
    ///   - `.unknown`    → can't determine (simulator, etc.)
    ///   - `.unplugged`  → running on battery
    ///   - `.charging`   → plugged in, charging
    ///   - `.full`       → plugged in, fully charged
    private func updateChargingState() {
        let state = UIDevice.current.batteryState

        // Consider "charging" or "full" as "plugged in."
        let wasCharging = isCharging
        isCharging = (state == .charging || state == .full)

        // If the device just got plugged in, reset the warning flags.
        // This way, if the user unplugs again later and the battery
        // drops below the threshold, we'll warn them again.
        if isCharging && !wasCharging {
            hasWarned = false
            hasFiredCritical = false
        }
    }

    /// Compare the current battery level against our thresholds and
    /// fire the appropriate callback if needed.
    ///
    /// We only fire each callback ONCE per discharge cycle to avoid
    /// spamming the user with repeated warnings.
    private func checkThresholds() {
        // Don't warn if the device is plugged in — it's charging!
        guard !isCharging else { return }

        // Convert battery level (0.0–1.0) to a percentage (0–100).
        let percent = batteryLevel * 100.0

        // ── Critical threshold (≤ 2%) ──
        // The device could shut down at any moment. Auto-stop the stream
        // and finalize any recording to prevent data loss.
        if percent <= BatteryMonitor.criticalThresholdPercent && !hasFiredCritical {
            hasFiredCritical = true
            hasWarned = true  // No need to warn separately if already critical.
            onCriticalBattery?()
            return
        }

        // ── Warning threshold (default 5%, configurable) ──
        // Show a warning so the user can decide to stop or plug in.
        let warningThreshold = Float(settingsRepository.getLowBatteryThreshold())
        if percent <= warningThreshold && !hasWarned {
            hasWarned = true
            onLowBatteryWarning?()
        }
    }
}
