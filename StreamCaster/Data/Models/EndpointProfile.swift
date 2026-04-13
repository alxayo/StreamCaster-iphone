import Foundation

// MARK: - EndpointProfile
/// Stores the information needed to connect to a single RTMP server.
/// Users can save multiple profiles (e.g., "Twitch", "YouTube", "Custom")
/// and pick the one they want before going live.
struct EndpointProfile: Identifiable, Codable, Equatable {
    /// Unique identifier for this profile (a UUID string like
    /// "E621E1F8-C36C-495A-93FC-0C247A3E6E5F").
    let id: String

    /// User-chosen display name (e.g., "My Twitch Channel").
    var name: String

    /// The full RTMP ingest URL, starting with `rtmp://` or `rtmps://`.
    /// Example: "rtmp://live.twitch.tv/app"
    var rtmpUrl: String

    /// The secret stream key provided by the streaming platform.
    /// This is sensitive — stored in the Keychain, not UserDefaults.
    var streamKey: String

    /// Optional username for RTMP servers that require authentication.
    var username: String?

    /// Optional password for RTMP servers that require authentication.
    var password: String?

    /// When `true`, this profile is selected automatically when the app launches.
    /// Only one profile should be marked as the default at a time.
    var isDefault: Bool = false

    /// The video codec to use when streaming to this endpoint.
    /// Defaults to H.264 for maximum compatibility.
    /// H.265 and AV1 require Enhanced RTMP server support.
    var videoCodec: VideoCodec = .h264
}
