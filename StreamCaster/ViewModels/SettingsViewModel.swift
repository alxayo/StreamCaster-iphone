// SettingsViewModel.swift
// StreamCaster
//
// Manages the state for all settings screens (Video, Audio, General).
// Reads saved preferences from SettingsRepository and writes them back
// whenever the user changes something. Also queries device capabilities
// so the UI only shows options the hardware actually supports.

import Foundation
import AVFoundation
import Combine

/// SettingsViewModel manages the state for all settings screens.
/// It reads/writes user preferences through the SettingsRepository
/// and queries device capabilities to show only supported options.
@MainActor
class SettingsViewModel: ObservableObject {

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Video)
    // ──────────────────────────────────────────────────────────

    /// The user's chosen video resolution (e.g., 1280×720).
    @Published var selectedResolution: Resolution {
        didSet {
            // Save immediately whenever the user picks a new resolution
            settingsRepo.setResolution(selectedResolution)
            // Different resolutions support different frame rates,
            // so refresh the list when resolution changes
            updateAvailableFrameRates()
        }
    }

    /// The user's chosen frames-per-second (e.g., 30).
    @Published var selectedFps: Int {
        didSet { settingsRepo.setFps(selectedFps) }
    }

    /// Target video bitrate in kilobits per second (e.g., 2500).
    @Published var videoBitrateKbps: Int {
        didSet { settingsRepo.setVideoBitrate(videoBitrateKbps) }
    }

    /// How often to insert a keyframe, in seconds (1–5).
    @Published var keyframeIntervalSec: Int {
        didSet { settingsRepo.setKeyframeInterval(keyframeIntervalSec) }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Audio)
    // ──────────────────────────────────────────────────────────

    /// Target audio bitrate in kilobits per second (e.g., 128).
    @Published var audioBitrateKbps: Int {
        didSet { settingsRepo.setAudioBitrate(audioBitrateKbps) }
    }

    /// Audio sample rate in Hz (44100 or 48000).
    @Published var audioSampleRate: Int {
        didSet { settingsRepo.setAudioSampleRate(audioSampleRate) }
    }

    /// true = stereo (2 channels), false = mono (1 channel).
    @Published var isStereo: Bool {
        didSet { settingsRepo.setStereo(isStereo) }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Encoder)
    // ──────────────────────────────────────────────────────────

    /// Whether Adaptive Bitrate is enabled (auto-adjusts quality
    /// based on network conditions).
    @Published var isAbrEnabled: Bool {
        didSet { settingsRepo.setAbrEnabled(isAbrEnabled) }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Camera & Orientation)
    // ──────────────────────────────────────────────────────────

    /// Which camera to use by default on launch (.front or .back).
    @Published var defaultCameraPosition: AVCaptureDevice.Position {
        didSet {
            settingsRepo.setDefaultCameraPosition(defaultCameraPosition)
            // Resolution/FPS support can differ per camera, so refresh
            updateAvailableResolutions()
        }
    }

    /// "landscape" or "portrait" — locks orientation while streaming.
    @Published var preferredOrientation: String {
        didSet {
            // Store as Int: 1 = landscape, 0 = portrait
            let orientationInt = preferredOrientation == "landscape" ? 1 : 0
            settingsRepo.setPreferredOrientation(orientationInt)
        }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Network & Battery)
    // ──────────────────────────────────────────────────────────

    /// Max reconnect attempts before giving up. Int.max means unlimited.
    @Published var reconnectMaxAttempts: Int {
        didSet { settingsRepo.setReconnectMaxAttempts(reconnectMaxAttempts) }
    }

    /// Battery % below which the app shows a warning (1–20).
    @Published var lowBatteryThreshold: Int {
        didSet { settingsRepo.setLowBatteryThreshold(lowBatteryThreshold) }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Recording)
    // ──────────────────────────────────────────────────────────

    /// Whether to save a local copy of the stream on-device.
    @Published var isLocalRecordingEnabled: Bool {
        didSet { settingsRepo.setLocalRecordingEnabled(isLocalRecordingEnabled) }
    }

    /// Where recordings are saved: Photos library or Documents folder.
    @Published var recordingDestination: RecordingDestination {
        didSet { settingsRepo.setRecordingDestination(recordingDestination) }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Available Options (filtered by device hardware)
    // ──────────────────────────────────────────────────────────

    /// Resolutions the current camera supports (e.g., [480p, 720p, 1080p]).
    @Published var availableResolutions: [Resolution] = []

    /// Frame rates available at the currently selected resolution.
    @Published var availableFrameRates: [Int] = []

    /// Camera positions physically present on this device.
    @Published var availableCameras: [AVCaptureDevice.Position] = []

    // ──────────────────────────────────────────────────────────
    // MARK: - Dependencies
    // ──────────────────────────────────────────────────────────

    /// Repository that reads/writes settings to UserDefaults.
    private let settingsRepo: SettingsRepository

    /// Queries real hardware to find supported resolutions, FPS, cameras.
    private let capabilityQuery: DeviceCapabilityQuery

    // ──────────────────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────────────────

    /// Creates a new SettingsViewModel, loading all saved settings
    /// from the repository and querying device capabilities.
    ///
    /// - Parameters:
    ///   - settingsRepo: Where settings are stored (UserDefaults).
    ///   - capabilityQuery: Queries which resolutions/FPS the camera supports.
    init(
        settingsRepo: SettingsRepository,
        capabilityQuery: DeviceCapabilityQuery
    ) {
        self.settingsRepo = settingsRepo
        self.capabilityQuery = capabilityQuery

        // Load every saved setting from the repository.
        // If the user has never changed a setting, the repository
        // returns a sensible default (e.g., 720p, 30 fps).
        self.selectedResolution = settingsRepo.getResolution()
        self.selectedFps = settingsRepo.getFps()
        self.videoBitrateKbps = settingsRepo.getVideoBitrate()
        self.audioBitrateKbps = settingsRepo.getAudioBitrate()
        self.audioSampleRate = settingsRepo.getAudioSampleRate()
        self.isStereo = settingsRepo.isStereo()
        self.keyframeIntervalSec = settingsRepo.getKeyframeInterval()
        self.isAbrEnabled = settingsRepo.isAbrEnabled()
        self.defaultCameraPosition = settingsRepo.getDefaultCameraPosition()
        self.reconnectMaxAttempts = settingsRepo.getReconnectMaxAttempts()
        self.lowBatteryThreshold = settingsRepo.getLowBatteryThreshold()
        self.isLocalRecordingEnabled = settingsRepo.isLocalRecordingEnabled()
        self.recordingDestination = settingsRepo.getRecordingDestination()

        // Convert the stored Int orientation back to a human-readable string.
        // 1 = landscape (default), anything else = portrait.
        let orientationInt = settingsRepo.getPreferredOrientation()
        self.preferredOrientation = orientationInt == 1 ? "landscape" : "portrait"

        // Query the device hardware for available cameras and resolutions
        self.availableCameras = capabilityQuery.availableCameras()
        loadAvailableOptions()
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────────────────

    /// Loads both available resolutions and frame rates based on
    /// the currently selected camera. Called once during init.
    private func loadAvailableOptions() {
        updateAvailableResolutions()
    }

    /// Refreshes the list of resolutions the selected camera supports.
    /// If the current resolution is no longer available, picks the
    /// closest match.
    private func updateAvailableResolutions() {
        let resolutions = capabilityQuery.supportedResolutions(
            for: defaultCameraPosition
        )
        availableResolutions = resolutions

        // If the current resolution isn't supported by this camera,
        // fall back to the last available resolution (usually the highest).
        if !resolutions.contains(selectedResolution), let fallback = resolutions.last {
            selectedResolution = fallback
        }

        // Also refresh frame rates for the (possibly new) resolution
        updateAvailableFrameRates()
    }

    /// Refreshes the list of frame rates available at the current
    /// resolution. If the current FPS is no longer valid, picks the
    /// closest match.
    private func updateAvailableFrameRates() {
        let frameRates = capabilityQuery.supportedFrameRates(
            for: selectedResolution,
            camera: defaultCameraPosition
        )
        availableFrameRates = frameRates

        // If the current FPS isn't supported at this resolution,
        // fall back to the last available frame rate (usually the highest).
        if !frameRates.contains(selectedFps), let fallback = frameRates.last {
            selectedFps = fallback
        }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Display Helpers
    // ──────────────────────────────────────────────────────────

    /// Human-readable label for a resolution, e.g. "720p (1280×720)".
    func resolutionLabel(for resolution: Resolution) -> String {
        // The "p" value is the height (e.g., 720p, 1080p)
        return "\(resolution.height)p (\(resolution.width)×\(resolution.height))"
    }

    /// Human-readable label for a camera position, e.g. "Back Camera".
    func cameraLabel(for position: AVCaptureDevice.Position) -> String {
        switch position {
        case .back:
            return "Back Camera"
        case .front:
            return "Front Camera"
        default:
            return "Unknown"
        }
    }

    /// Human-readable label for reconnect attempts.
    /// Int.max is shown as "Unlimited".
    func reconnectLabel(for value: Int) -> String {
        return value == Int.max ? "Unlimited" : "\(value)"
    }
}
