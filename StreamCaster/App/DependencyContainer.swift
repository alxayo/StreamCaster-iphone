// DependencyContainer.swift
// StreamCaster
//
// A simple dependency injection (DI) container.
// DI means we create services in one central place and share them
// throughout the app, instead of creating them everywhere.

import Foundation

/// The DependencyContainer holds references to all shared services.
/// Using a singleton (`shared`) so every part of the app accesses
/// the same instance.
///
/// As we build out features, we'll add properties here like:
/// - CameraService (manages the camera hardware)
/// - AudioService (manages microphone capture)
/// - StreamService (handles RTMP connection)
/// - SettingsManager (persists user preferences)
/// - CrashReporter (tracks and reports crashes)
final class DependencyContainer {

    // MARK: - Singleton

    /// The single shared instance used across the entire app.
    static let shared = DependencyContainer()

    // Private init prevents others from creating additional instances.
    private init() {
        // TODO: Initialize and wire up services here
    }

    // MARK: - Services (to be added)

    // Example of what will go here:
    //
    // lazy var cameraService: CameraService = { CameraService() }()
    // lazy var audioService: AudioService = { AudioService() }()
    // lazy var streamService: StreamService = { StreamService() }()
    // lazy var settingsManager: SettingsManager = { SettingsManager() }()
}
