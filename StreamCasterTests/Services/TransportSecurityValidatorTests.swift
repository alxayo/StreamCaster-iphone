import XCTest
@testable import StreamCaster

// MARK: - TransportSecurityValidatorTests
/// Tests for TransportSecurityValidator — the gatekeeper that checks whether
/// an RTMP connection is safe to make.
///
/// WHY THESE TESTS MATTER:
/// If the validator incorrectly classifies a plaintext URL as secure,
/// the user's stream key and credentials could be sent unencrypted.
/// If it blocks a valid RTMPS URL, the user can't stream at all.
///
/// SECURITY RULES BEING TESTED:
/// - RTMPS (rtmps://) → always allowed (encrypted with TLS)
/// - RTMP (rtmp://)   → warning (plaintext, but some servers only support it)

final class TransportSecurityValidatorTests: XCTestCase {

    // MARK: - Helper

    /// Creates a simple EndpointProfile for testing.
    ///
    /// Most tests only care about the URL (and sometimes credentials),
    /// so this helper fills in the other fields with dummy values.
    ///
    /// - Parameters:
    ///   - url: The RTMP URL to test (e.g., "rtmps://live.example.com/app").
    ///   - username: Optional username for auth testing. Defaults to nil.
    ///   - password: Optional password for auth testing. Defaults to nil.
    /// - Returns: An EndpointProfile ready for validation.
    private func makeProfile(
        url: String,
        username: String? = nil,
        password: String? = nil
    ) -> EndpointProfile {
        return EndpointProfile(
            id: "test-\(UUID().uuidString)",
            name: "Test Profile",
            rtmpUrl: url,
            streamKey: "test-stream-key",
            username: username,
            password: password
        )
    }

    // MARK: - RTMPS (Secure) Tests

    /// Verify that an rtmps:// URL returns .allowed.
    ///
    /// RTMPS uses TLS encryption, so it's always safe. The validator
    /// should give the green light without any warnings.
    func testRTMPSIsAllowed() {
        let profile = makeProfile(url: "rtmps://live.example.com/app")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .allowed,
            "RTMPS URLs should always be allowed — they use TLS encryption.")
    }

    /// Verify that RTMPS works even with UPPERCASE letters.
    ///
    /// Users might type "RTMPS://" or "Rtmps://" — the validator should
    /// handle any case variation. URL schemes are case-insensitive per RFC 3986.
    func testRTMPSUppercaseIsAllowed() {
        let profile = makeProfile(url: "RTMPS://LIVE.EXAMPLE.COM/app")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .allowed,
            "RTMPS in uppercase should still be recognized as secure.")
    }

    /// Verify that mixed-case RTMPS is also recognized.
    ///
    /// Edge case: "RtMpS://..." should still be treated as secure.
    func testRTMPSMixedCaseIsAllowed() {
        let profile = makeProfile(url: "RtMpS://live.example.com/app")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .allowed,
            "Mixed-case RTMPS should still be recognized as secure.")
    }

    // MARK: - RTMP (Plaintext) Tests

    /// Verify that a plain rtmp:// URL returns .warningPlaintext.
    ///
    /// Plain RTMP sends everything unencrypted. The validator should warn
    /// the user but still allow the connection (some servers only support RTMP).
    func testPlainRTMPReturnsWarning() {
        let profile = makeProfile(url: "rtmp://live.example.com/app")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .warningPlaintext,
            "Plain RTMP should return a warning — data is sent unencrypted.")
    }

    /// Verify that uppercase RTMP also returns a warning.
    ///
    /// Same logic as the RTMPS case-insensitivity test, but for plain RTMP.
    func testPlainRTMPUppercaseReturnsWarning() {
        let profile = makeProfile(url: "RTMP://live.example.com/app")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .warningPlaintext,
            "Uppercase RTMP should still be detected as plaintext.")
    }

    // MARK: - isSecureURL Tests

    /// Verify that isSecureURL returns true for an rtmps:// URL.
    ///
    /// This is the core building block — `validate()` depends on this method.
    func testIsSecureURLWithRTMPS() {
        let isSecure = TransportSecurityValidator.isSecureURL("rtmps://example.com")

        XCTAssertTrue(isSecure,
            "rtmps:// URLs should be recognized as secure.")
    }

    /// Verify that isSecureURL returns false for a plain rtmp:// URL.
    ///
    /// Plain RTMP has no encryption, so isSecureURL must return false.
    func testIsSecureURLWithRTMP() {
        let isSecure = TransportSecurityValidator.isSecureURL("rtmp://example.com")

        XCTAssertFalse(isSecure,
            "rtmp:// URLs should NOT be recognized as secure — no encryption.")
    }

    /// Verify that isSecureURL is case-insensitive.
    ///
    /// The implementation uses .lowercased() before checking the prefix,
    /// so "RTMPS://", "Rtmps://", and "rtmps://" should all return true.
    func testIsSecureURLCaseInsensitive() {
        // Test various case combinations.
        XCTAssertTrue(
            TransportSecurityValidator.isSecureURL("RTMPS://EXAMPLE.COM"),
            "All-uppercase RTMPS should be recognized as secure.")
        XCTAssertTrue(
            TransportSecurityValidator.isSecureURL("Rtmps://Example.com"),
            "Title-case RTMPS should be recognized as secure.")
        XCTAssertTrue(
            TransportSecurityValidator.isSecureURL("rTmPs://example.com"),
            "Random-case RTMPS should be recognized as secure.")
    }

    // MARK: - Profile Validation with Credentials

    /// Verify that an RTMPS profile with credentials returns .allowed.
    ///
    /// When both the URL is encrypted AND credentials are present, the
    /// connection is fully secure. Credentials are protected by TLS.
    func testValidateSecureProfileWithCredentials() {
        let profile = makeProfile(
            url: "rtmps://ingest.example.com/live",
            username: "broadcaster",
            password: "s3cret"
        )

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .allowed,
            "RTMPS with credentials should be allowed — TLS protects everything.")
    }

    /// Verify that a plain RTMP profile without credentials returns .warningPlaintext.
    ///
    /// Even without credentials, plaintext RTMP is still insecure because
    /// the stream key (in the URL path) is visible to network observers.
    func testValidatePlainProfileNoCredentials() {
        let profile = makeProfile(url: "rtmp://ingest.example.com/live")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .warningPlaintext,
            "Plain RTMP without credentials should still warn about plaintext.")
    }

    /// Verify that a plain RTMP profile WITH credentials also returns .warningPlaintext.
    ///
    /// This is a particularly dangerous case — credentials would be sent
    /// in the clear. The validator warns but does not block (the caller
    /// decides how to handle the warning).
    func testValidatePlainProfileWithCredentialsWarns() {
        let profile = makeProfile(
            url: "rtmp://ingest.example.com/live",
            username: "broadcaster",
            password: "s3cret"
        )

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .warningPlaintext,
            "Plain RTMP with credentials should warn — creds would be sent in plaintext.")
    }

    // MARK: - Edge Cases

    /// Verify that RTMPS with a custom port is still recognized as secure.
    ///
    /// Some servers use non-standard ports (e.g., rtmps://server:8443/live).
    /// The port shouldn't affect the security classification.
    func testRTMPSWithCustomPortIsAllowed() {
        let profile = makeProfile(url: "rtmps://server.example.com:8443/live")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .allowed,
            "RTMPS with a custom port should still be allowed.")
    }

    /// Verify that RTMP with a custom port returns a warning.
    func testRTMPWithCustomPortReturnsWarning() {
        let profile = makeProfile(url: "rtmp://server.example.com:1936/live")

        let result = TransportSecurityValidator.validate(profile: profile)

        XCTAssertEqual(result, .warningPlaintext,
            "RTMP with a custom port should still be classified as plaintext.")
    }
}
