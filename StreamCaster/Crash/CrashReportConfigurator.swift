import Foundation

/// CrashReportConfigurator sets up crash reporting for the app.
///
/// We use KSCrash (an open-source crash reporter) to capture crash reports
/// and send them to our server. This is important for finding and fixing
/// bugs that happen on users' devices.
///
/// SECURITY: All crash reports are sanitized using CredentialSanitizer
/// to remove any stream keys, passwords, or other secrets before sending.
/// Reports are only sent over HTTPS — never plain HTTP.
///
/// NOTE: Crash reporting is only enabled in RELEASE builds (not DEBUG)
/// because during development we use Xcode's built-in debugger instead.
struct CrashReportConfigurator {

    /// The HTTPS endpoint where crash reports will be sent
    /// TODO: Set this to the actual crash reporting server URL (OQ-02)
    private static let crashEndpointURL = "https://crashes.example.com/api/reports"

    // MARK: - Public API

    /// Initialize crash reporting. Call this from AppDelegate.didFinishLaunching.
    /// This method is safe to call — if KSCrash fails to initialize,
    /// the app will still launch normally.
    static func configure() {
        // Only enable crash reporting in release builds.
        // During development, Xcode's debugger gives us better tools.
        #if !DEBUG
        do {
            try setupCrashReporting()
        } catch {
            // If crash reporting fails to set up, log the error but don't crash.
            // The app should always launch even if crash reporting is broken.
            print("⚠️ Crash reporting setup failed: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Setup

    /// Internal setup logic, separated so errors can be thrown and caught.
    private static func setupCrashReporting() throws {
        // TODO: When KSCrash SPM dependency is resolved, uncomment and implement:
        // 1. Create KSCrash instance
        // 2. Configure with HTTPS-only transport (reject http:// endpoints)
        // 3. Register CredentialSanitizer as a report filter
        // 4. Install crash handlers
        //
        // For now, this is a placeholder that will be completed when
        // the KSCrash dependency is available.

        // Validate that the configured endpoint uses HTTPS before proceeding.
        // This is a security requirement — crash reports may contain device
        // information and we never want to send that over plain HTTP.
        guard let url = URL(string: crashEndpointURL),
              url.scheme == "https" else {
            throw CrashReportError.insecureEndpoint
        }
    }

    // MARK: - Endpoint Validation

    /// Validate that a crash report endpoint uses HTTPS.
    ///
    /// - Parameter urlString: The URL string to check.
    /// - Returns: `true` if the URL is safe to use (HTTPS, or HTTP on local network for testing).
    static func isEndpointSecure(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        // Allow HTTPS always — it's encrypted and safe
        if url.scheme == "https" { return true }
        // Allow HTTP only for local network (RFC 1918) addresses, which is
        // useful during development and testing
        if url.scheme == "http", let host = url.host {
            return isLocalNetwork(host)
        }
        return false
    }

    /// Check if a host is on a local/private network (RFC 1918).
    ///
    /// Private networks (like 192.168.x.x) never leave your local router,
    /// so HTTP is acceptable there for development purposes.
    ///
    /// - Parameter host: The hostname or IP address to check.
    /// - Returns: `true` if the host is a known private/local address.
    private static func isLocalNetwork(_ host: String) -> Bool {
        // Common local network patterns
        return host == "localhost" ||
               host == "127.0.0.1" ||
               host.hasPrefix("192.168.") ||
               host.hasPrefix("10.") ||
               host.hasPrefix("172.16.") || host.hasPrefix("172.17.") ||
               host.hasPrefix("172.18.") || host.hasPrefix("172.19.") ||
               host.hasPrefix("172.20.") || host.hasPrefix("172.21.") ||
               host.hasPrefix("172.22.") || host.hasPrefix("172.23.") ||
               host.hasPrefix("172.24.") || host.hasPrefix("172.25.") ||
               host.hasPrefix("172.26.") || host.hasPrefix("172.27.") ||
               host.hasPrefix("172.28.") || host.hasPrefix("172.29.") ||
               host.hasPrefix("172.30.") || host.hasPrefix("172.31.")
    }

    // MARK: - Report Sanitization

    /// Sanitize a crash report dictionary before sending.
    ///
    /// This removes any stream keys, passwords, or tokens that might
    /// have been captured in the crash report's metadata or stack trace.
    ///
    /// - Parameter report: The raw crash report dictionary from KSCrash.
    /// - Returns: A cleaned dictionary safe to send over the network.
    static func sanitizeReport(_ report: [String: Any]) -> [String: Any] {
        return CredentialSanitizer.sanitizeDictionary(report)
    }
}

// MARK: - Error Types

/// Errors that can occur during crash report configuration.
/// Each case provides a human-readable description via `LocalizedError`.
enum CrashReportError: LocalizedError {
    /// The configured endpoint does not use HTTPS
    case insecureEndpoint
    /// KSCrash failed to initialize for the given reason
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint:
            return "Crash report endpoint must use HTTPS"
        case .initializationFailed(let reason):
            return "Crash reporting initialization failed: \(reason)"
        }
    }
}
