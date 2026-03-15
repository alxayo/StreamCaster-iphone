import Foundation

// MARK: - TransportSecurityValidator

/// TransportSecurityValidator enforces the app's transport security rules.
///
/// SECURITY RULES:
/// 1. RTMPS (rtmps://) — Always allowed. Uses system TLS. No custom cert bypass.
/// 2. RTMP (rtmp://) with credentials — BLOCKED. Stream keys and passwords
///    must NEVER be sent in plaintext. This is a hard security requirement.
/// 3. RTMP (rtmp://) without credentials — Allowed. Some test/local servers
///    don't need authentication, and plaintext is acceptable for those.
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

        /// BLOCKED — the URL uses plain rtmp:// AND there are credentials
        /// (stream key, username, or password) that would be sent in cleartext.
        /// The connection must NOT proceed.
        case blockedPlaintextWithCredentials

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

        // Step 2: Does the profile contain any secrets?
        // A stream key, username, or password counts as credentials.
        let hasCredentials = !profile.streamKey.isEmpty ||
                             profile.username != nil ||
                             profile.password != nil

        // Step 3: Apply the security rules.
        // RTMPS is always fine — traffic is encrypted.
        if isSecure { return .allowed }

        // Plain RTMP + credentials = BLOCKED.
        // Sending secrets in cleartext is never acceptable.
        if hasCredentials { return .blockedPlaintextWithCredentials }

        // Plain RTMP without credentials = warn but allow.
        // Useful for local test servers (e.g., rtmp://localhost/live).
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
