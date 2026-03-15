import Foundation
import AVFoundation

// MARK: - SettingsRepository
/// Reads and writes *non-sensitive* user preferences that are stored in
/// UserDefaults. Sensitive data like stream keys belong in the Keychain
/// (see `EndpointProfileRepository`).
///
/// Each getter/setter pair handles one setting. Implementations should
/// provide sensible default values when a setting has never been written.
protocol SettingsRepository {

    // MARK: Video Settings

    /// Get the user's preferred video resolution (e.g., 1280×720).
    func getResolution() -> Resolution

    /// Save the user's preferred video resolution.
    func setResolution(_ resolution: Resolution)

    /// Get the user's preferred frames-per-second (e.g., 30).
    func getFps() -> Int

    /// Save the user's preferred frames-per-second.
    func setFps(_ fps: Int)

    /// Get the target video bitrate in kilobits per second (e.g., 2500).
    func getVideoBitrate() -> Int

    /// Save the target video bitrate in kilobits per second.
    func setVideoBitrate(_ kbps: Int)

    // MARK: Audio Settings

    /// Get the target audio bitrate in kilobits per second (e.g., 128).
    func getAudioBitrate() -> Int

    /// Save the target audio bitrate in kilobits per second.
    func setAudioBitrate(_ kbps: Int)

    /// Get the audio sample rate in Hz (e.g., 44100).
    func getAudioSampleRate() -> Int

    /// Save the audio sample rate in Hz.
    func setAudioSampleRate(_ hz: Int)

    /// Check whether stereo (2-channel) audio is enabled.
    func isStereo() -> Bool

    /// Enable or disable stereo audio.
    func setStereo(_ enabled: Bool)

    // MARK: Encoder Settings

    /// Get the keyframe interval in seconds (e.g., 2).
    func getKeyframeInterval() -> Int

    /// Save the keyframe interval in seconds.
    func setKeyframeInterval(_ seconds: Int)

    /// Check whether Adaptive Bitrate (ABR) is turned on.
    func isAbrEnabled() -> Bool

    /// Enable or disable Adaptive Bitrate.
    func setAbrEnabled(_ enabled: Bool)

    // MARK: Camera Settings

    /// Get the camera that should be used when the app launches
    /// (e.g., `.back` for the rear camera).
    func getDefaultCameraPosition() -> AVCaptureDevice.Position

    /// Save the default camera position.
    func setDefaultCameraPosition(_ position: AVCaptureDevice.Position)

    /// Get the preferred capture orientation (as the raw `Int` value of
    /// `AVCaptureVideoOrientation` or a custom enum). Defaults to landscape.
    func getPreferredOrientation() -> Int

    /// Save the preferred capture orientation.
    func setPreferredOrientation(_ orientation: Int)

    // MARK: Reconnect Settings

    /// Get the maximum number of automatic reconnect attempts before giving up.
    func getReconnectMaxAttempts() -> Int

    /// Save the maximum number of reconnect attempts.
    func setReconnectMaxAttempts(_ count: Int)

    // MARK: Battery Settings

    /// Get the battery percentage below which the app should warn the user
    /// or stop streaming (e.g., 10 means 10 %).
    func getLowBatteryThreshold() -> Int

    /// Save the low-battery warning threshold.
    func setLowBatteryThreshold(_ percent: Int)

    // MARK: Recording Settings

    /// Check whether local recording (saving a copy on-device) is enabled.
    func isLocalRecordingEnabled() -> Bool

    /// Enable or disable local recording.
    func setLocalRecordingEnabled(_ enabled: Bool)

    /// Get where recordings should be saved (Photos library or Documents folder).
    func getRecordingDestination() -> RecordingDestination

    /// Save the recording destination preference.
    func setRecordingDestination(_ destination: RecordingDestination)
}
