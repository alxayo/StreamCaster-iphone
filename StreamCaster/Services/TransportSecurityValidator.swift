import Foundation

// MARK: - TransportSecurityValidator

/// TransportSecurityValidator enforces the app's transport security rules.
///
/// SECURITY RULES:
/// 1. RTMPS (rtmps://) — Always allowed. Uses system TLS. No custom cert bypass.
/// 2. RTMP (rtmp://) — Allowed with warning. Plaintext transport is still
///    insecure, but some ingest servers only support RTMP.
///
/// We use iOS's built-in TLS (Network.framework / URLSession). We NEVER:
/// - Override SecTrustEvaluate
/// - Set NSAllowsArbitraryLoads
/// - Implement custom certificate pinning
/// Users with self-signed certs must install them via iOS Settings.
struct TransportSecurityValidator {

    // MARK: - ValidationResult

    /// Result of a security validation check.
    /// Each case tells the caller what to do next.
    enum ValidationResult: Equatable {
        /// Safe to proceed — the URL uses RTMPS (encrypted).
        case allowed

        /// The URL uses plain rtmp://, but there are no credentials.
        /// Warn the user but let them continue if they want to.
        case warningPlaintext
    }

    // MARK: - Validation

    /// Validate whether a connection to this profile is allowed.
    ///
    /// Call this BEFORE attempting to connect. The returned result tells
    /// the caller whether to proceed, warn, or block the connection.
    ///
    /// - Parameter profile: The endpoint profile the user wants to connect to.
    /// - Returns: A `ValidationResult` indicating what to do.
    static func validate(profile: EndpointProfile) -> ValidationResult {
        // Step 1: Is the URL encrypted (rtmps://)?
        let isSecure = isSecureURL(profile.rtmpUrl)

        // Step 2: Apply the security rules.
        // RTMPS is always fine — traffic is encrypted.
        if isSecure { return .allowed }

        // Plain RTMP = warn but allow.
        // Useful for ingest services that do not support RTMPS.
        return .warningPlaintext
    }

    /// Check if a URL uses the secure RTMPS scheme.
    ///
    /// - Parameter url: The RTMP URL string (e.g., "rtmps://live.twitch.tv/app").
    /// - Returns: `true` if the URL starts with "rtmps://", case-insensitive.
    static func isSecureURL(_ url: String) -> Bool {
        // lowercased() so "RTMPS://..." also matches.
        url.lowercased().hasPrefix("rtmps://")
    }
}
