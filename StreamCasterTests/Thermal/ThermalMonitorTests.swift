// ThermalMonitorTests.swift
// StreamCasterTests
//
// Unit tests for ThermalMonitor and the ThermalLevel enum.
//
// These tests verify:
//   1. ThermalMonitor starts in the correct default state.
//   2. ThermalLevel raw values are stable (important for Codable/JSON).
//   3. ThermalLevel can round-trip through JSON encoding/decoding.
//   4. Anti-oscillation helpers (cooldown, backoff, blacklist) work correctly.

import XCTest
import Combine
@testable import StreamCaster

final class ThermalMonitorTests: XCTestCase {

    // MARK: - Initial State Tests

    /// When a ThermalMonitor is first created (before startMonitoring is called),
    /// its currentLevel should default to .normal — the device is assumed to be cool.
    func testInitialThermalLevelIsNormal() {
        // Create a fresh monitor — no startMonitoring() call.
        let monitor = ThermalMonitor()

        // The default thermal level should be .normal (cool device).
        XCTAssertEqual(
            monitor.currentLevel,
            .normal,
            "A new ThermalMonitor should start at .normal thermal level"
        )
    }

    // MARK: - ThermalLevel Enum Tests

    /// Verify that each ThermalLevel case has the expected raw string value.
    /// Raw values are used when encoding to JSON (Codable), so they must
    /// remain stable across app versions to avoid breaking saved data.
    func testThermalLevelRawValues() {
        XCTAssertEqual(ThermalLevel.normal.rawValue, "normal",
                       ".normal raw value must be 'normal' for Codable stability")
        XCTAssertEqual(ThermalLevel.fair.rawValue, "fair",
                       ".fair raw value must be 'fair' for Codable stability")
        XCTAssertEqual(ThermalLevel.serious.rawValue, "serious",
                       ".serious raw value must be 'serious' for Codable stability")
        XCTAssertEqual(ThermalLevel.critical.rawValue, "critical",
                       ".critical raw value must be 'critical' for Codable stability")
    }

    /// Confirm all four ThermalLevel cases exist by collecting them into an array.
    /// If someone accidentally removes or renames a case, this test will fail.
    func testAllThermalLevelCasesExist() {
        // List every expected case explicitly.
        let allCases: [ThermalLevel] = [.normal, .fair, .serious, .critical]

        // We expect exactly 4 thermal levels.
        XCTAssertEqual(
            allCases.count,
            4,
            "ThermalLevel should have exactly 4 cases: normal, fair, serious, critical"
        )
    }

    /// Encode each ThermalLevel to JSON and decode it back.
    /// This ensures Codable conformance works correctly — important because
    /// ThermalLevel is stored in StreamStats, which may be serialized.
    func testThermalLevelCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test every case to make sure none are broken.
        let allCases: [ThermalLevel] = [.normal, .fair, .serious, .critical]

        for originalLevel in allCases {
            // Encode: ThermalLevel → JSON data (e.g., "normal")
            let jsonData = try encoder.encode(originalLevel)

            // Decode: JSON data → ThermalLevel
            let decodedLevel = try decoder.decode(ThermalLevel.self, from: jsonData)

            // The decoded value should match the original exactly.
            XCTAssertEqual(
                decodedLevel,
                originalLevel,
                "ThermalLevel.\(originalLevel) should survive a JSON round-trip"
            )
        }
    }

    /// Verify that ThermalLevel equality works as expected.
    /// Same cases should be equal; different cases should not be.
    func testThermalLevelEquality() {
        // Same case → equal
        XCTAssertEqual(ThermalLevel.normal, ThermalLevel.normal,
                       ".normal should equal .normal")
        XCTAssertEqual(ThermalLevel.critical, ThermalLevel.critical,
                       ".critical should equal .critical")

        // Different cases → not equal
        XCTAssertNotEqual(ThermalLevel.normal, ThermalLevel.fair,
                          ".normal should NOT equal .fair")
        XCTAssertNotEqual(ThermalLevel.fair, ThermalLevel.serious,
                          ".fair should NOT equal .serious")
        XCTAssertNotEqual(ThermalLevel.serious, ThermalLevel.critical,
                          ".serious should NOT equal .critical")
    }

    // MARK: - Anti-Oscillation Tests

    /// When no thermal change has been recorded yet, the cooldown should
    /// NOT be active — the monitor should allow the first change freely.
    func testCooldownNotActiveInitially() {
        let monitor = ThermalMonitor()

        // No thermal change has been recorded, so cooldown should be off.
        XCTAssertFalse(
            monitor.isCooldownActive(),
            "Cooldown should not be active before any thermal change is recorded"
        )
    }

    /// After recording a thermal change, the cooldown should be active
    /// (we're within the 60-second minimum window).
    func testCooldownActiveAfterRecordingChange() {
        let monitor = ThermalMonitor()

        // Simulate a thermal quality change just happened.
        monitor.recordThermalChange()

        // The cooldown should now be active because < 60 seconds have passed.
        XCTAssertTrue(
            monitor.isCooldownActive(),
            "Cooldown should be active immediately after recording a thermal change"
        )
    }

    /// When cooldown is not active, remaining seconds should be 0.
    func testCooldownRemainingIsZeroInitially() {
        let monitor = ThermalMonitor()

        // No change recorded → 0 seconds remaining.
        XCTAssertEqual(
            monitor.cooldownRemainingSeconds(),
            0,
            "Cooldown remaining should be 0 when no thermal change has been recorded"
        )
    }

    /// After recording a change, cooldown remaining should be close to 60 seconds
    /// (the full cooldown window, minus the tiny amount of time since the call).
    func testCooldownRemainingAfterRecordingChange() {
        let monitor = ThermalMonitor()
        monitor.recordThermalChange()

        let remaining = monitor.cooldownRemainingSeconds()

        // Should be close to 60 seconds. Allow a small margin for execution time.
        XCTAssertGreaterThan(remaining, 55,
                             "Cooldown remaining should be close to 60 seconds right after recording")
        XCTAssertLessThanOrEqual(remaining, 60,
                                 "Cooldown remaining should not exceed 60 seconds")
    }

    /// Verify the progressive restore backoff schedule:
    /// - First attempt:  60 seconds
    /// - Second attempt: 120 seconds
    /// - Third+ attempt: 300 seconds
    func testRestoreBackoffProgression() {
        let monitor = ThermalMonitor()

        // First restore attempt → 60 seconds backoff.
        XCTAssertEqual(monitor.currentRestoreBackoff(), 60,
                       "First restore backoff should be 60 seconds")

        // Record one restore attempt, then check second backoff.
        monitor.recordRestoreAttempt()
        XCTAssertEqual(monitor.currentRestoreBackoff(), 120,
                       "Second restore backoff should be 120 seconds")

        // Record another, then check third backoff.
        monitor.recordRestoreAttempt()
        XCTAssertEqual(monitor.currentRestoreBackoff(), 300,
                       "Third restore backoff should be 300 seconds (5 minutes)")

        // Further attempts should stay at 300 seconds (clamped to last value).
        monitor.recordRestoreAttempt()
        XCTAssertEqual(monitor.currentRestoreBackoff(), 300,
                       "Fourth+ restore backoff should still be 300 seconds")
    }

    /// Verify the static constants that control anti-oscillation timing.
    func testAntiOscillationConstants() {
        XCTAssertEqual(ThermalMonitor.minimumCooldownSeconds, 60,
                       "Minimum cooldown between thermal changes should be 60 seconds")
        XCTAssertEqual(ThermalMonitor.restoreBackoffSeconds, [60, 120, 300],
                       "Restore backoff schedule should be [60, 120, 300]")
    }

    // MARK: - Config Blacklist Tests

    /// A config should not be blacklisted by default.
    func testConfigNotBlacklistedByDefault() {
        let monitor = ThermalMonitor()

        // No configs have been blacklisted yet.
        XCTAssertFalse(
            monitor.isConfigBlacklisted("1280x720@30"),
            "No config should be blacklisted on a fresh monitor"
        )
    }

    /// After blacklisting a config, it should be reported as blacklisted.
    func testBlacklistConfig() {
        let monitor = ThermalMonitor()

        // Blacklist a specific resolution/fps combo that caused overheating.
        monitor.blacklistConfig("1920x1080@60")

        // That config should now be blacklisted.
        XCTAssertTrue(
            monitor.isConfigBlacklisted("1920x1080@60"),
            "A blacklisted config should be reported as blacklisted"
        )

        // Other configs should NOT be affected.
        XCTAssertFalse(
            monitor.isConfigBlacklisted("1280x720@30"),
            "Non-blacklisted configs should not be affected"
        )
    }

    // MARK: - Publisher Tests

    /// The thermalLevelPublisher should emit the current level immediately
    /// upon subscription (because it wraps a @Published property).
    func testThermalLevelPublisherEmitsCurrentValue() {
        let monitor = ThermalMonitor()
        var receivedLevels: [ThermalLevel] = []

        // Subscribe to the publisher. @Published sends the current value
        // immediately, so we should get .normal right away.
        let cancellable = monitor.thermalLevelPublisher
            .sink { level in
                receivedLevels.append(level)
            }

        // The publisher should have emitted .normal (the default).
        XCTAssertEqual(
            receivedLevels,
            [.normal],
            "thermalLevelPublisher should emit .normal immediately on subscription"
        )

        // Clean up the subscription to avoid memory leaks.
        cancellable.cancel()
    }
}
