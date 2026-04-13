import Foundation

// MARK: - Resolution
/// Represents a video resolution as a width × height pair.
/// Common values: 1920×1080 (Full HD), 1280×720 (HD), 854×480 (SD).
struct Resolution: Equatable, Codable, Hashable {
    /// Horizontal pixel count (e.g., 1280).
    let width: Int

    /// Vertical pixel count (e.g., 720).
    let height: Int

    /// Human-readable string like "1280x720".
    var description: String { "\(width)x\(height)" }
}

// MARK: - StreamConfig
/// All the settings needed to configure a streaming session *before* going live.
/// This combines network, video, and audio parameters into one place.
struct StreamConfig: Equatable {
    /// The ID of the `EndpointProfile` that this config will stream to.
    var profileId: String

    /// Whether to capture and send video. Set to `false` for audio-only streams.
    var videoEnabled: Bool = true

    /// Whether to capture and send audio. Set to `false` for video-only streams.
    var audioEnabled: Bool = true

    /// Video resolution to capture and encode (default: 1280×720 = 720p).
    var resolution: Resolution = Resolution(width: 1280, height: 720)

    /// Target frames per second (default: 30).
    var fps: Int = 30

    /// Target video bitrate in kilobits per second (default: 2500 = 2.5 Mbps).
    /// Higher values mean better quality but need more upload bandwidth.
    var videoBitrateKbps: Int = 2500

    /// Target audio bitrate in kilobits per second (default: 128).
    var audioBitrateKbps: Int = 128

    /// Audio sample rate in Hz (default: 44100 = CD quality).
    var audioSampleRate: Int = 44100

    /// `true` for stereo (2-channel) audio, `false` for mono (1-channel).
    var stereo: Bool = true

    /// How often to insert a keyframe, in seconds (default: 2).
    /// Shorter intervals help viewers join faster but use more bandwidth.
    var keyframeIntervalSec: Int = 2

    /// The video codec to use for encoding. See `VideoCodec` for details.
    /// This is read from the endpoint profile, not user settings.
    var videoCodec: VideoCodec = .h264

    /// Adaptive Bitrate — when `true`, the app automatically lowers the
    /// video bitrate if the network can't keep up, and raises it when it can.
    var abrEnabled: Bool = true

    /// Whether to save a local copy of the stream on the device.
    var localRecordingEnabled: Bool = false

    /// If local recording is enabled, `true` saves to the Photos library;
    /// `false` saves to the app's Documents folder.
    var recordToPhotosLibrary: Bool = true
}
