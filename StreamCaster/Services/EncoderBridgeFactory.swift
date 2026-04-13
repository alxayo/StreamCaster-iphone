import Foundation

// MARK: - EncoderBridgeFactory

/// Factory that creates the correct encoder bridge based on the streaming protocol.
///
/// The StreamCaster app supports two streaming protocols:
/// - **RTMP/RTMPS** → Uses `HaishinKitEncoderBridge` (traditional streaming)
/// - **SRT** → Uses `SRTEncoderBridge` (low-latency streaming)
///
/// This factory examines the endpoint URL to detect the protocol and returns
/// the appropriate bridge implementation. Both bridges conform to the same
/// `EncoderBridge` protocol, so the rest of the app doesn't need to know
/// which protocol is being used.
///
/// We use an `enum` with only `static` methods (no cases) — this is a Swift
/// pattern called a "caseless enum." It prevents anyone from accidentally
/// creating an instance of the factory, since a factory is just a collection
/// of helper methods, not something you store or pass around.
///
/// ## Usage
/// ```swift
/// let bridge = EncoderBridgeFactory.makeBridge(for: profile)
/// ```
enum EncoderBridgeFactory {

    /// Create an encoder bridge appropriate for the given endpoint profile.
    ///
    /// The protocol is detected from the profile's URL scheme:
    /// - `rtmp://` or `rtmps://` → `HaishinKitEncoderBridge`
    /// - `srt://` → `SRTEncoderBridge`
    /// - Unknown → Falls back to `HaishinKitEncoderBridge` (RTMP is the safe default)
    ///
    /// A **new** bridge instance is returned every time this is called.
    /// This is intentional — each stream session should get a fresh bridge
    /// so leftover state from a previous connection can't cause bugs.
    ///
    /// - Parameter profile: The endpoint profile containing the server URL.
    /// - Returns: An encoder bridge configured for the detected protocol.
    static func makeBridge(for profile: EndpointProfile) -> EncoderBridge {
        // Ask the profile which protocol its URL points to.
        // `detectedProtocol` inspects the URL scheme (rtmp://, rtmps://, srt://)
        // and returns the matching StreamProtocol case. If the scheme is
        // unrecognized, it defaults to .rtmp for backward compatibility.
        let proto = profile.detectedProtocol

        switch proto {
        case .srt:
            // SRT URLs (srt://host:port) use the SRT encoder bridge
            // which connects via Secure Reliable Transport protocol.
            // SRT is optimized for low-latency streaming over unreliable
            // networks like cellular or public Wi-Fi.
            return SRTEncoderBridge()

        case .rtmp:
            // RTMP/RTMPS URLs use the HaishinKit encoder bridge
            // which connects via Real-Time Messaging Protocol.
            // RTMP is the most widely supported protocol — works with
            // Twitch, YouTube, Facebook Live, and most streaming platforms.
            return HaishinKitEncoderBridge()
        }
    }
}
