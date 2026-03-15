// UserDefaultsSettingsRepository.swift
// StreamCaster
//
// Implements `SettingsRepository` using UserDefaults — the simplest way
// to persist small pieces of data on iOS.
//
// UserDefaults works like a dictionary that automatically saves to disk.
// It is great for user preferences (resolution, bitrate, etc.) but
// should NOT be used for large data or secrets.

import Foundation
import AVFoundation

/// Concrete implementation of `SettingsRepository` backed by
/// `UserDefaults.standard`.
///
/// **How it works:**
/// - Each setting has a unique string *key* (see `Keys` enum below).
/// - When you call a setter, the value is written to UserDefaults
///   immediately.
/// - When you call a getter, the value is read from UserDefaults. If
///   nothing has been stored yet the getter returns a sensible default
///   defined in `Defaults`.
final class UserDefaultsSettingsRepository: SettingsRepository {

    // MARK: - UserDefaults Keys
    // We keep all key strings in one place so they're easy to find and
    // impossible to misspell across getter/setter pairs.
    private enum Keys {
        static let resolution          = "settings.resolution"
        static let fps                 = "settings.fps"
        static let videoBitrate        = "settings.videoBitrate"
        static let audioBitrate        = "settings.audioBitrate"
        static let audioSampleRate     = "settings.audioSampleRate"
        static let stereo              = "settings.stereo"
        static let keyframeInterval    = "settings.keyframeInterval"
        static let abrEnabled          = "settings.abrEnabled"
        static let cameraPosition      = "settings.cameraPosition"
        static let orientation         = "settings.orientation"
        static let reconnectMaxAttempts = "settings.reconnectMaxAttempts"
        static let lowBatteryThreshold = "settings.lowBatteryThreshold"
        static let localRecording      = "settings.localRecording"
        static let recordingDestination = "settings.recordingDestination"
    }

    // MARK: - Defaults
    // Sensible factory defaults that match the project specification.
    // These are used when the user has never changed a setting.
    private enum Defaults {
        static let resolution          = Resolution(width: 1280, height: 720) // 720p HD
        static let fps                 = 30
        static let videoBitrateKbps    = 2500       // 2.5 Mbps
        static let audioBitrateKbps    = 128
        static let audioSampleRate     = 44100      // CD-quality
        static let stereo              = true
        static let keyframeInterval    = 2           // seconds
        static let abrEnabled          = true
        static let cameraPosition      = AVCaptureDevice.Position.back
        static let orientation         = 1           // 1 = landscape (matches AVCaptureVideoOrientation.landscapeRight)
        static let reconnectMaxAttempts = Int.max    // unlimited
        static let lowBatteryThreshold = 5           // 5 %
        static let localRecording      = false
        static let recordingDestination = RecordingDestination.photosLibrary
    }

    // MARK: - Storage

    /// The UserDefaults instance we read from and write to.
    /// Using `.standard` means data is shared across the whole app.
    private let defaults: UserDefaults

    /// You can inject a custom `UserDefaults` for unit testing.
    /// In production we just use `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Helpers

    /// Returns `true` if UserDefaults contains a value for this key.
    /// We need this because `integer(forKey:)` returns 0 when the key
    /// is missing — we can't tell "not set" from "set to 0".
    private func hasValue(forKey key: String) -> Bool {
        return defaults.object(forKey: key) != nil
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Video Settings
    // ──────────────────────────────────────────────────────────────

    func getResolution() -> Resolution {
        // Resolution is stored as a string like "1280x720".
        guard let stored = defaults.string(forKey: Keys.resolution) else {
            return Defaults.resolution
        }
        // Split the string by "x" and convert each part to an Int.
        let parts = stored.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            // If the stored string is corrupt, fall back to the default.
            return Defaults.resolution
        }
        return Resolution(width: width, height: height)
    }

    func setResolution(_ resolution: Resolution) {
        // Store as "WIDTHxHEIGHT" string, e.g. "1920x1080".
        defaults.set("\(resolution.width)x\(resolution.height)", forKey: Keys.resolution)
    }

    func getFps() -> Int {
        return hasValue(forKey: Keys.fps)
            ? defaults.integer(forKey: Keys.fps)
            : Defaults.fps
    }

    func setFps(_ fps: Int) {
        defaults.set(fps, forKey: Keys.fps)
    }

    func getVideoBitrate() -> Int {
        return hasValue(forKey: Keys.videoBitrate)
            ? defaults.integer(forKey: Keys.videoBitrate)
            : Defaults.videoBitrateKbps
    }

    func setVideoBitrate(_ kbps: Int) {
        defaults.set(kbps, forKey: Keys.videoBitrate)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Audio Settings
    // ──────────────────────────────────────────────────────────────

    func getAudioBitrate() -> Int {
        return hasValue(forKey: Keys.audioBitrate)
            ? defaults.integer(forKey: Keys.audioBitrate)
            : Defaults.audioBitrateKbps
    }

    func setAudioBitrate(_ kbps: Int) {
        defaults.set(kbps, forKey: Keys.audioBitrate)
    }

    func getAudioSampleRate() -> Int {
        return hasValue(forKey: Keys.audioSampleRate)
            ? defaults.integer(forKey: Keys.audioSampleRate)
            : Defaults.audioSampleRate
    }

    func setAudioSampleRate(_ hz: Int) {
        defaults.set(hz, forKey: Keys.audioSampleRate)
    }

    func isStereo() -> Bool {
        // `bool(forKey:)` returns false when the key is missing,
        // so we need `hasValue` to distinguish "not set" from "set to false".
        return hasValue(forKey: Keys.stereo)
            ? defaults.bool(forKey: Keys.stereo)
            : Defaults.stereo
    }

    func setStereo(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.stereo)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Encoder Settings
    // ──────────────────────────────────────────────────────────────

    func getKeyframeInterval() -> Int {
        return hasValue(forKey: Keys.keyframeInterval)
            ? defaults.integer(forKey: Keys.keyframeInterval)
            : Defaults.keyframeInterval
    }

    func setKeyframeInterval(_ seconds: Int) {
        defaults.set(seconds, forKey: Keys.keyframeInterval)
    }

    func isAbrEnabled() -> Bool {
        return hasValue(forKey: Keys.abrEnabled)
            ? defaults.bool(forKey: Keys.abrEnabled)
            : Defaults.abrEnabled
    }

    func setAbrEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.abrEnabled)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Camera Settings
    // ──────────────────────────────────────────────────────────────

    func getDefaultCameraPosition() -> AVCaptureDevice.Position {
        guard hasValue(forKey: Keys.cameraPosition) else {
            return Defaults.cameraPosition
        }
        // AVCaptureDevice.Position is backed by an Int raw value:
        //   0 = unspecified, 1 = back, 2 = front
        let rawValue = defaults.integer(forKey: Keys.cameraPosition)
        return AVCaptureDevice.Position(rawValue: rawValue) ?? Defaults.cameraPosition
    }

    func setDefaultCameraPosition(_ position: AVCaptureDevice.Position) {
        // Store the integer raw value so we can reconstruct it later.
        defaults.set(position.rawValue, forKey: Keys.cameraPosition)
    }

    func getPreferredOrientation() -> Int {
        return hasValue(forKey: Keys.orientation)
            ? defaults.integer(forKey: Keys.orientation)
            : Defaults.orientation
    }

    func setPreferredOrientation(_ orientation: Int) {
        defaults.set(orientation, forKey: Keys.orientation)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Reconnect Settings
    // ──────────────────────────────────────────────────────────────

    func getReconnectMaxAttempts() -> Int {
        return hasValue(forKey: Keys.reconnectMaxAttempts)
            ? defaults.integer(forKey: Keys.reconnectMaxAttempts)
            : Defaults.reconnectMaxAttempts
    }

    func setReconnectMaxAttempts(_ count: Int) {
        defaults.set(count, forKey: Keys.reconnectMaxAttempts)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Battery Settings
    // ──────────────────────────────────────────────────────────────

    func getLowBatteryThreshold() -> Int {
        return hasValue(forKey: Keys.lowBatteryThreshold)
            ? defaults.integer(forKey: Keys.lowBatteryThreshold)
            : Defaults.lowBatteryThreshold
    }

    func setLowBatteryThreshold(_ percent: Int) {
        defaults.set(percent, forKey: Keys.lowBatteryThreshold)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Recording Settings
    // ──────────────────────────────────────────────────────────────

    func isLocalRecordingEnabled() -> Bool {
        return hasValue(forKey: Keys.localRecording)
            ? defaults.bool(forKey: Keys.localRecording)
            : Defaults.localRecording
    }

    func setLocalRecordingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.localRecording)
    }

    func getRecordingDestination() -> RecordingDestination {
        // RecordingDestination is a String-backed enum, so we store its
        // rawValue (e.g., "photosLibrary" or "documents").
        guard let stored = defaults.string(forKey: Keys.recordingDestination),
              let destination = RecordingDestination(rawValue: stored) else {
            return Defaults.recordingDestination
        }
        return destination
    }

    func setRecordingDestination(_ destination: RecordingDestination) {
        defaults.set(destination.rawValue, forKey: Keys.recordingDestination)
    }
}
