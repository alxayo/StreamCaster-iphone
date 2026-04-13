import XCTest
@testable import StreamCaster

// MARK: - CrashReportConfiguratorTests
/// Tests for CrashReportConfigurator – the component that sets up crash
/// reporting and ensures reports are sent securely.
///
/// KEY SECURITY RULES VERIFIED HERE:
///   1. Crash reports must ONLY be sent over HTTPS (encrypted).
///   2. HTTP is allowed ONLY for local/private network addresses
///      (RFC 1918) so developers can test with a local server.
///   3. Reports must be sanitized (no credentials) before sending.
final class CrashReportConfiguratorTests: XCTestCase {

    // ---------------------------------------------------------------
    // MARK: - HTTPS Endpoints (should be secure)
    // ---------------------------------------------------------------

    /// An HTTPS URL is always considered secure because the traffic
    /// is encrypted with TLS. This is the normal production case.
    func testHTTPSEndpointIsSecure() {
        XCTAssertTrue(
            CrashReportConfigurator.isEndpointSecure("https://crashes.example.com"),
            "HTTPS endpoints must always be considered secure"
        )
    }

    /// HTTPS with a path and port should also pass.
    func testHTTPSEndpointWithPathIsSecure() {
        XCTAssertTrue(
            CrashReportConfigurator.isEndpointSecure("https://crashes.example.com:8443/api/reports"),
            "HTTPS with a port and path should still be secure"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - HTTP on Public Internet (should NOT be secure)
    // ---------------------------------------------------------------

    /// Plain HTTP on a public server is NOT secure — data travels
    /// in cleartext and could be intercepted by anyone on the network.
    func testHTTPEndpointIsNotSecure() {
        XCTAssertFalse(
            CrashReportConfigurator.isEndpointSecure("http://crashes.example.com"),
            "HTTP to a public server must NOT be considered secure"
        )
    }

    /// Even a public IP address over HTTP is not safe.
    func testHTTPPublicIPIsNotSecure() {
        XCTAssertFalse(
            CrashReportConfigurator.isEndpointSecure("http://8.8.8.8/api"),
            "HTTP to a public IP (8.8.8.8) must NOT be secure"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - HTTP on Local/Private Networks (RFC 1918 exceptions)
    // ---------------------------------------------------------------
    // During development, it's common to run a local crash server.
    // HTTP is acceptable here because the traffic never leaves your
    // local network (your home/office router).

    /// `localhost` is the machine itself — always safe.
    func testHTTPLocalhostIsSecure() {
        XCTAssertTrue(
            CrashReportConfigurator.isEndpointSecure("http://localhost:8080"),
            "HTTP to localhost should be secure (local loopback)"
        )
    }

    /// `127.0.0.1` is the IPv4 loopback — same as localhost.
    func testHTTPLoopbackIPIsSecure() {
        XCTAssertTrue(
            CrashReportConfigurator.isEndpointSecure("http://127.0.0.1:8080"),
            "HTTP to 127.0.0.1 should be secure (IPv4 loopback)"
        )
    }

    /// `192.168.x.x` addresses are private (RFC 1918).
    /// These are typical home/office LAN addresses.
    func testHTTP192168IsSecure() {
        XCTAssertTrue(
            CrashReportConfigurator.isEndpointSecure("http://192.168.1.1/api"),
            "HTTP to 192.168.x.x should be secure (private network)"
        )
    }

    /// `10.x.x.x` addresses are also private (RFC 1918).
    /// Often used in corporate or VPN networks.
    func testHTTP10NetworkIsSecure() {
        XCTAssertTrue(
            CrashReportConfigurator.isEndpointSecure("http://10.0.0.1/api"),
            "HTTP to 10.x.x.x should be secure (private network)"
        )
    }

    /// `172.16.x.x` through `172.31.x.x` are private (RFC 1918).
    func testHTTP172PrivateRangeIsSecure() {
        XCTAssertTrue(
            CrashReportConfigurator.isEndpointSecure("http://172.16.0.1/api"),
            "HTTP to 172.16.x.x should be secure (private network)"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - Invalid URLs
    // ---------------------------------------------------------------

    /// A completely invalid URL string should be treated as insecure.
    /// We can't verify security if we can't even parse the URL.
    func testInvalidURLIsNotSecure() {
        XCTAssertFalse(
            CrashReportConfigurator.isEndpointSecure("not a url"),
            "Unparseable strings must be considered insecure"
        )
    }

    /// An empty string is also not a valid URL.
    func testEmptyStringIsNotSecure() {
        XCTAssertFalse(
            CrashReportConfigurator.isEndpointSecure(""),
            "Empty string must be considered insecure"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - Report Sanitization
    // ---------------------------------------------------------------

    /// `sanitizeReport` delegates to CredentialSanitizer.sanitizeDictionary.
    /// Verify that a report dictionary containing a credential comes
    /// back with that credential removed.
    func testSanitizeReportRemovesCredentials() {
        // Simulate a crash report that accidentally captured a stream URL
        let report: [String: Any] = [
            "crash_reason": "EXC_BAD_ACCESS",
            "user_data": "Connected to rtmp://host/app/sk_live_topSecret"
        ]

        let sanitized = CrashReportConfigurator.sanitizeReport(report)

        // The crash reason has no credentials — should be unchanged
        XCTAssertEqual(
            sanitized["crash_reason"] as? String,
            "EXC_BAD_ACCESS",
            "Non-sensitive fields should remain unchanged"
        )

        // The user_data field contained a stream key — must be redacted
        let userData = sanitized["user_data"] as? String ?? ""
        XCTAssertFalse(
            userData.contains("topSecret"),
            "Stream key must not appear in the sanitized report"
        )
        XCTAssertTrue(
            userData.contains("[REDACTED]"),
            "Sanitized report should contain the [REDACTED] placeholder"
        )
    }

    /// Verify sanitization works on nested report structures.
    func testSanitizeReportHandlesNestedDictionaries() {
        let report: [String: Any] = [
            "crash_info": [
                "last_log": #"{"password": "hunter2"}"#
            ] as [String: Any]
        ]

        let sanitized = CrashReportConfigurator.sanitizeReport(report)

        // Dig into the nested dictionary
        let crashInfo = sanitized["crash_info"] as? [String: Any]
        let lastLog = crashInfo?["last_log"] as? String ?? ""

        XCTAssertFalse(
            lastLog.contains("hunter2"),
            "Nested password values must be redacted in reports"
        )
        XCTAssertTrue(
            lastLog.contains("[REDACTED]"),
            "Nested sanitized fields should contain [REDACTED]"
        )
    }
}
