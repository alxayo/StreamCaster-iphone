// DependencyContainer.swift
// StreamCaster
//
// ──────────────────────────────────────────────────────────────────
// What is Dependency Injection (DI)?
// ──────────────────────────────────────────────────────────────────
//
// Normally, when a class needs to use another class, it creates it
// directly — like calling `let repo = SettingsRepoImpl()`. The
// problem? That class is now permanently tied to one specific
// implementation, making it hard to test or replace.
//
// With DI, we flip the control: instead of each class creating its
// own dependencies, we create ALL dependencies in ONE central place
// (this file!) and hand them to whichever class needs them. Classes
// only know about *protocols* (interfaces), never concrete types.
//
// Benefits:
//   • Easy testing — swap in a mock implementation for unit tests.
//   • Single source of truth — change a dependency once, here.
//   • Loose coupling — classes don't know (or care) which concrete
//     type they're talking to.
// ──────────────────────────────────────────────────────────────────

import Foundation

/// The DependencyContainer is the single place where every shared
/// service in the app is created, configured, and wired together.
///
/// We use the singleton pattern (`DependencyContainer.shared`) so
/// that every screen and service in the app accesses the same
/// instances.
///
/// Each property is declared with `lazy var`, which means the object
/// is only created the first time something asks for it — not at app
/// launch. This keeps startup fast.
final class DependencyContainer {

    // MARK: - Singleton

    /// The one and only instance of the container. Access it from
    /// anywhere with `DependencyContainer.shared`.
    static let shared = DependencyContainer()

    /// Private init prevents anyone from creating a second container.
    /// All access must go through `DependencyContainer.shared`.
    private init() {}

    // MARK: - Data Layer

    /// Reads and writes user preferences (resolution, bitrate, etc.)
    /// backed by UserDefaults.
    lazy var settingsRepository: SettingsRepository = {
        UserDefaultsSettingsRepository()
    }()

    /// Manages RTMP endpoint profiles (server URL + stream key).
    /// Sensitive data like stream keys are stored in the iOS Keychain.
    lazy var endpointProfileRepository: EndpointProfileRepository = {
        KeychainEndpointProfileRepository()
    }()

    // MARK: - Camera

    /// Queries the device hardware to find out which cameras, resolutions,
    /// and frame rates are available on this specific iPhone/iPad.
    lazy var deviceCapabilityQuery: DeviceCapabilityQuery = {
        AVDeviceCapabilityQuery()
    }()

    // MARK: - Streaming Services

    /// The main streaming engine — connects to the RTMP server, manages
    /// the camera/microphone, and publishes real-time state updates.
    lazy var streamingEngine: StreamingEngineProtocol = {
        // TODO: Replace with real implementation (e.g., StreamingEngine)
        fatalError("StreamingEngine not yet implemented")
    }()

    /// Low-level bridge to the encoding/publishing library (HaishinKit).
    /// The streaming engine talks to this instead of calling HaishinKit
    /// directly, so we can swap libraries or use a mock in tests.
    lazy var encoderBridge: EncoderBridge = {
        // TODO: Replace with real implementation (e.g., HaishinKitEncoderBridge)
        fatalError("EncoderBridge not yet implemented")
    }()

    /// Decides how long to wait between automatic reconnect attempts
    /// when the RTMP connection drops. Uses exponential backoff by
    /// default: 3 s → 6 s → 12 s → … up to 60 s, with random jitter
    /// to avoid "thundering herd" problems.
    lazy var reconnectPolicy: ReconnectPolicy = {
        ExponentialBackoffReconnectPolicy()
    }()

    // MARK: - Overlay

    /// Processes each video frame before encoding, allowing overlays
    /// like watermarks, chat messages, or a "LIVE" badge to be
    /// composited on top of the camera feed.
    lazy var overlayManager: OverlayManager = {
        NoOpOverlayManager()
    }()

    // MARK: - System Monitors

    /// Watches the device's thermal state (how hot the phone is).
    /// When the device overheats, the streaming engine can reduce
    /// quality automatically (lower bitrate, drop frame rate).
    lazy var thermalMonitor: ThermalMonitorProtocol = {
        // TODO: Replace with real implementation (e.g., ProcessInfoThermalMonitor)
        fatalError("ThermalMonitor not yet implemented")
    }()

    // MARK: - Audio

    /// Manages the iOS audio session — configures it for live streaming,
    /// handles interruptions (phone calls, Siri), and reports when the
    /// audio route changes (headphones plugged in, Bluetooth connected).
    lazy var audioSessionManager: AudioSessionManagerProtocol = {
        // TODO: Replace with real implementation (e.g., AVAudioSessionManager)
        fatalError("AudioSessionManager not yet implemented")
    }()
}
