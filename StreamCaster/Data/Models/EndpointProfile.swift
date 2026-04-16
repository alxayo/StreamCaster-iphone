import Foundation

// MARK: - EndpointProfile
/// Stores the information needed to connect to a single streaming server.
/// Users can save multiple profiles (e.g., "Twitch", "YouTube", "Custom")
/// and pick the one they want before going live.
///
/// Supports both RTMP/RTMPS and SRT protocols. The protocol is auto-detected
/// from the URL scheme (`rtmp://`, `rtmps://`, or `srt://`).
struct EndpointProfile: Identifiable, Codable, Equatable {

    // ──────────────────────────────────────────────────────────
    // MARK: - Core Fields (used by all protocols)
    // ──────────────────────────────────────────────────────────

    /// Unique identifier for this profile (a UUID string like
    /// "E621E1F8-C36C-495A-93FC-0C247A3E6E5F").
    let id: String

    /// User-chosen display name (e.g., "My Twitch Channel").
    var name: String

    /// The full ingest URL, starting with `rtmp://`, `rtmps://`, or `srt://`.
    /// Examples:
    ///   - RTMP:  "rtmp://live.twitch.tv/app"
    ///   - SRT:   "srt://ingest.server.com:9000"
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

    // ──────────────────────────────────────────────────────────
    // MARK: - SRT-Specific Fields
    // ──────────────────────────────────────────────────────────
    // These fields are only meaningful when the URL scheme is `srt://`.
    // They are ignored for RTMP/RTMPS connections.

    /// The SRT connection mode (caller, listener, or rendezvous).
    /// Only used when the URL scheme is `srt://`.
    /// Defaults to `.caller` which is the most common mode —
    /// the phone connects out to a server that's already listening.
    var srtMode: SRTMode = .caller

    /// The SRT passphrase for AES encryption (10–79 characters).
    /// If nil or empty, the SRT connection is unencrypted.
    /// This is separate from RTMP stream key authentication.
    var srtPassphrase: String?

    /// The AES encryption key length used when `srtPassphrase` is set.
    /// Determines the strength of the encryption: AES-128, AES-192, or AES-256.
    /// Defaults to `.aes256` (the current industry standard).
    /// Ignored when `srtPassphrase` is nil or empty (no encryption).
    var srtKeyLength: SRTKeyLength = .aes256

    /// The SRT latency in milliseconds.
    /// Higher values provide more resilience to network jitter but increase delay.
    /// Default is 120ms — a good balance for most networks.
    /// Range: 20ms (aggressive) to 8000ms (very lossy networks).
    var srtLatencyMs: Int = 120

    /// The SRT stream ID, used by some servers to route streams.
    /// Similar to RTMP's stream key but for SRT connections.
    /// If nil, no stream ID is sent (fine for most SRT servers).
    var srtStreamId: String?

    // ──────────────────────────────────────────────────────────
    // MARK: - Memberwise Initializer
    // ──────────────────────────────────────────────────────────

    /// Creates an endpoint profile with all fields.
    ///
    /// SRT fields are optional and default to sensible values (caller mode,
    /// 120ms latency) so callers that only need RTMP don't have to specify them.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (typically `UUID().uuidString`).
    ///   - name: User-facing display name.
    ///   - rtmpUrl: The full ingest URL (rtmp://, rtmps://, or srt://).
    ///   - streamKey: The secret key from the streaming platform.
    ///   - username: Optional RTMP auth username.
    ///   - password: Optional RTMP auth password.
    ///   - isDefault: Whether this is the auto-selected profile on launch.
    ///   - videoCodec: Video codec to use (default: H.264).
    ///   - srtMode: SRT connection mode (default: caller).
    ///   - srtPassphrase: Optional SRT encryption passphrase.
    ///   - srtKeyLength: AES key length for SRT encryption (default: AES-256).
    ///   - srtLatencyMs: SRT latency in milliseconds (default: 120).
    ///   - srtStreamId: Optional SRT stream routing ID.
    init(
        id: String,
        name: String,
        rtmpUrl: String,
        streamKey: String,
        username: String? = nil,
        password: String? = nil,
        isDefault: Bool = false,
        videoCodec: VideoCodec = .h264,
        srtMode: SRTMode = .caller,
        srtPassphrase: String? = nil,
        srtKeyLength: SRTKeyLength = .aes256,
        srtLatencyMs: Int = 120,
        srtStreamId: String? = nil
    ) {
        self.id            = id
        self.name          = name
        self.rtmpUrl       = rtmpUrl
        self.streamKey     = streamKey
        self.username      = username
        self.password      = password
        self.isDefault     = isDefault
        self.videoCodec    = videoCodec
        self.srtMode       = srtMode
        self.srtPassphrase = srtPassphrase
        self.srtKeyLength  = srtKeyLength
        self.srtLatencyMs  = srtLatencyMs
        self.srtStreamId   = srtStreamId
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Computed Properties
    // ──────────────────────────────────────────────────────────

    /// The detected streaming protocol based on the endpoint URL.
    /// Returns `.rtmp` by default if the URL scheme is not recognized.
    ///
    /// This is computed (not stored) so it always reflects the current URL.
    /// If a user changes their URL from `rtmp://` to `srt://`, the
    /// protocol updates automatically without a separate field.
    var detectedProtocol: StreamProtocol {
        StreamProtocol.detect(from: rtmpUrl) ?? .rtmp
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Codable
    // ──────────────────────────────────────────────────────────

    /// Explicit CodingKeys so we control exactly which properties are
    /// serialized. The computed `detectedProtocol` is excluded because
    /// it can always be recalculated from `rtmpUrl`.
    enum CodingKeys: String, CodingKey {
        case id, name, rtmpUrl, streamKey
        case username, password, isDefault
        case videoCodec
        case srtMode, srtPassphrase, srtKeyLength, srtLatencyMs, srtStreamId
    }

    /// Custom decoder that gracefully handles JSON from older app versions.
    ///
    /// When we add new fields (like the SRT properties), existing profiles
    /// stored on disk won't have those keys. Using `decodeIfPresent` lets
    /// us fall back to sensible defaults instead of crashing on old data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Core fields — always present in any version of the JSON.
        id        = try container.decode(String.self, forKey: .id)
        name      = try container.decode(String.self, forKey: .name)
        rtmpUrl   = try container.decode(String.self, forKey: .rtmpUrl)
        streamKey = try container.decode(String.self, forKey: .streamKey)

        // Optional core fields — may be nil in the JSON.
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)

        // Fields added after v1 — use decodeIfPresent so old JSON still works.
        isDefault  = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        videoCodec = try container.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? .h264

        // SRT fields — new in this version, won't exist in older JSON.
        srtMode       = try container.decodeIfPresent(SRTMode.self, forKey: .srtMode) ?? .caller
        srtPassphrase = try container.decodeIfPresent(String.self, forKey: .srtPassphrase)
        srtKeyLength  = try container.decodeIfPresent(SRTKeyLength.self, forKey: .srtKeyLength) ?? .aes256
        srtLatencyMs  = try container.decodeIfPresent(Int.self, forKey: .srtLatencyMs) ?? 120
        srtStreamId   = try container.decodeIfPresent(String.self, forKey: .srtStreamId)
    }
}
