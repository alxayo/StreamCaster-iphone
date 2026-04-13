import Foundation

// MARK: - StreamProtocol

/// The streaming transport protocol used to send media data to the server.
///
/// StreamCaster supports two protocols:
/// - **RTMP/RTMPS**: The traditional Real-Time Messaging Protocol, widely supported
///   by platforms like YouTube, Twitch, and Facebook Live. RTMPS adds TLS encryption.
/// - **SRT**: Secure Reliable Transport, a newer protocol optimized for low-latency
///   streaming over unreliable networks (e.g., cellular, public internet).
///
/// The protocol is determined automatically from the endpoint URL scheme:
/// - `rtmp://` or `rtmps://` → RTMP
/// - `srt://` → SRT
enum StreamProtocol: String, Codable, CaseIterable, Sendable {
    /// RTMP (Real-Time Messaging Protocol) — the most widely supported streaming protocol.
    /// Use `rtmp://` for unencrypted or `rtmps://` for TLS-encrypted connections.
    case rtmp

    /// SRT (Secure Reliable Transport) — optimized for low-latency streaming
    /// over unreliable networks. Supports encryption via passphrase.
    case srt

    /// Human-readable display name for the protocol.
    var displayName: String {
        switch self {
        case .rtmp: return "RTMP / RTMPS"
        case .srt: return "SRT"
        }
    }

    /// Brief description of what the protocol is best for.
    var subtitle: String {
        switch self {
        case .rtmp: return "Traditional streaming — widest platform support"
        case .srt: return "Low-latency — best for unreliable networks"
        }
    }

    /// Detects the protocol from a URL string by examining the scheme.
    ///
    /// Examples:
    /// ```
    /// StreamProtocol.detect(from: "rtmp://live.twitch.tv/app")   // → .rtmp
    /// StreamProtocol.detect(from: "rtmps://live.twitch.tv/app")  // → .rtmp
    /// StreamProtocol.detect(from: "srt://ingest.server.com:9000") // → .srt
    /// StreamProtocol.detect(from: "https://example.com")          // → nil
    /// ```
    ///
    /// - Parameter urlString: The endpoint URL to inspect.
    /// - Returns: The detected protocol, or `nil` if the scheme is not recognized.
    static func detect(from urlString: String) -> StreamProtocol? {
        // Normalize to lowercase and strip whitespace so "  RTMP://..." still works.
        let lowered = urlString.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered.hasPrefix("rtmp://") || lowered.hasPrefix("rtmps://") {
            return .rtmp
        } else if lowered.hasPrefix("srt://") {
            return .srt
        }
        return nil
    }
}

// MARK: - SRTMode

/// SRT connection mode determines how the SRT socket connects to the remote peer.
///
/// SRT supports three modes that match the Android implementation:
/// - **caller**: The app initiates the connection to a remote SRT listener (most common).
/// - **listener**: The app listens for incoming SRT connections (rare, for ingest servers).
/// - **rendezvous**: Both sides connect simultaneously (NAT traversal without port forwarding).
///
/// Most streaming use cases use `.caller` mode — the phone calls out to
/// a server that's already listening for connections.
enum SRTMode: String, Codable, CaseIterable, Sendable {
    /// The app initiates the connection to a remote SRT listener.
    /// This is the default and most common mode for mobile streaming.
    case caller

    /// The app listens for incoming SRT connections.
    /// Rarely used — typically only when the phone acts as an ingest server.
    case listener

    /// Both sides connect simultaneously to each other.
    /// Useful for NAT traversal when neither side can open a port.
    case rendezvous

    /// Human-readable display name for settings UI.
    var displayName: String {
        switch self {
        case .caller: return "Caller"
        case .listener: return "Listener"
        case .rendezvous: return "Rendezvous"
        }
    }

    /// Short explanation of what this mode does, shown below the picker.
    var subtitle: String {
        switch self {
        case .caller: return "Connect to a remote server (default)"
        case .listener: return "Wait for incoming connections"
        case .rendezvous: return "Both sides connect simultaneously"
        }
    }
}
