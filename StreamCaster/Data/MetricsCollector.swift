// MetricsCollector.swift
// StreamCaster
//
// ──────────────────────────────────────────────────────────────────
// MetricsCollector tracks internal diagnostic counters.
// These help us understand app health and debug issues.
//
// Metrics are purely internal — they are NOT sent to any server
// and contain NO personal information. They exist only for
// on-device debugging and diagnostic displays.
//
// Example usage:
//   MetricsCollector.shared.recordEncoderInit(success: true)
//   MetricsCollector.shared.recordReconnectAttempt(success: false)
//   print("Reconnect attempts: \(MetricsCollector.shared.reconnectAttempts)")
// ──────────────────────────────────────────────────────────────────

import Foundation

final class MetricsCollector: ObservableObject {

    // MARK: - Singleton

    /// The one and only instance. Use `MetricsCollector.shared` everywhere.
    static let shared = MetricsCollector()

    /// Private init prevents creating additional instances.
    private init() {}

    // MARK: - Counters
    // Each counter is @Published so SwiftUI views (like a debug screen)
    // can observe and display them in real time.

    /// How many times the video/audio encoder was set up successfully.
    @Published private(set) var encoderInitSuccess: Int = 0

    /// How many times the encoder failed to initialize.
    /// A high number here suggests a hardware or configuration problem.
    @Published private(set) var encoderInitFailure: Int = 0

    /// Total number of automatic reconnect attempts since the app launched.
    @Published private(set) var reconnectAttempts: Int = 0

    /// How many of those reconnect attempts succeeded.
    /// Compare with `reconnectAttempts` to see the success rate.
    @Published private(set) var reconnectSuccesses: Int = 0

    /// How many times the device changed thermal state (e.g., normal → serious).
    @Published private(set) var thermalTransitions: Int = 0

    /// How many times writing to local storage failed (e.g., disk full).
    @Published private(set) var storageWriteErrors: Int = 0

    /// How many times Picture-in-Picture was successfully activated.
    @Published private(set) var pipActivations: Int = 0

    /// How many times Picture-in-Picture failed to start.
    @Published private(set) var pipFailures: Int = 0

    /// How many times a system permission was denied (camera, microphone, etc.).
    @Published private(set) var permissionDenials: Int = 0

    // MARK: - Recording Methods
    // Each method increments the appropriate counter(s).
    // Call these from wherever the event happens in the app.

    /// Record whether the encoder initialized successfully or failed.
    ///
    /// - Parameter success: `true` if init succeeded, `false` if it failed.
    func recordEncoderInit(success: Bool) {
        if success {
            encoderInitSuccess += 1
        } else {
            encoderInitFailure += 1
        }
    }

    /// Record a reconnect attempt and whether it succeeded.
    ///
    /// - Parameter success: `true` if reconnection was successful.
    func recordReconnectAttempt(success: Bool) {
        reconnectAttempts += 1
        if success {
            reconnectSuccesses += 1
        }
    }

    /// Record that the device changed thermal state.
    /// Called whenever iOS reports a thermal level change.
    func recordThermalTransition() {
        thermalTransitions += 1
    }

    /// Record a local storage write error (e.g., disk full during recording).
    func recordStorageError() {
        storageWriteErrors += 1
    }

    /// Record a Picture-in-Picture activation or failure.
    ///
    /// - Parameter success: `true` if PiP started, `false` if it failed.
    func recordPipEvent(success: Bool) {
        if success {
            pipActivations += 1
        } else {
            pipFailures += 1
        }
    }

    /// Record that a system permission was denied (camera, microphone, etc.).
    func recordPermissionDenial() {
        permissionDenials += 1
    }

    // MARK: - Reset

    /// Reset all counters to zero.
    /// Useful for starting a fresh diagnostic session.
    func reset() {
        encoderInitSuccess = 0
        encoderInitFailure = 0
        reconnectAttempts = 0
        reconnectSuccesses = 0
        thermalTransitions = 0
        storageWriteErrors = 0
        pipActivations = 0
        pipFailures = 0
        permissionDenials = 0
    }
}
