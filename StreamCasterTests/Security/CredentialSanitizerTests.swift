import XCTest
@testable import StreamCaster

// MARK: - CredentialSanitizerTests
/// Tests for CredentialSanitizer – the component that strips sensitive data
/// (stream keys, passwords, tokens) from strings before they appear in
/// crash reports or logs.
///
/// WHY THESE TESTS MATTER:
///   If the sanitizer has a bug, real user credentials could leak into
///   analytics dashboards or log files. Every regex pattern needs at
///   least one positive test (proves it catches the secret) and the
///   suite needs negative tests (proves it doesn't mangle normal text).
final class CredentialSanitizerTests: XCTestCase {

    // ---------------------------------------------------------------
    // MARK: - Redacted Placeholder
    // ---------------------------------------------------------------

    /// Verify the placeholder constant is exactly "[REDACTED]".
    /// Other parts of the codebase may rely on this exact string
    /// (e.g., to detect already-sanitized text), so it must not change
    /// without updating those callers too.
    func testRedactedPlaceholderValue() {
        XCTAssertEqual(
            CredentialSanitizer.redactedPlaceholder,
            "[REDACTED]",
            "The placeholder must be the literal string [REDACTED]"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - RTMP URL Stream Keys
    // ---------------------------------------------------------------

    /// RTMP URLs have the stream key as the last path segment:
    ///   rtmp://server/app/STREAM_KEY
    /// The sanitizer should keep the scheme + host + app and replace
    /// the key portion with [REDACTED].
    func testSanitizeRTMPUrlWithStreamKey() {
        let input    = "rtmp://live.twitch.tv/app/sk_live_abc123"
        let expected = "rtmp://live.twitch.tv/app/[REDACTED]"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "The stream key after /app/ should be replaced with [REDACTED]"
        )
    }

    /// Same test but with the TLS variant `rtmps://`.
    /// Many services (Twitch, YouTube) now require RTMPS.
    func testSanitizeRTMPSUrlWithStreamKey() {
        let input    = "rtmps://live.twitch.tv/app/sk_live_abc123"
        let expected = "rtmps://live.twitch.tv/app/[REDACTED]"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "RTMPS stream keys should be redacted just like RTMP ones"
        )
    }

    /// When a stream key appears inside a longer log message, the
    /// sanitizer should still find and redact it. The regex is not
    /// anchored to the start/end of the string.
    func testSanitizeStreamKeyInLogMessage() {
        let input    = "Connected to rtmp://host/app/sk_live_secret successfully"
        // Note: the (.+) in the regex is greedy, so it captures everything
        // after the app path — including trailing text on the same line.
        let expected = "Connected to rtmp://host/app/[REDACTED]"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "Stream keys embedded in log lines should still be caught"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - Query Parameter Credentials
    // ---------------------------------------------------------------

    /// Query parameters like `?key=SECRET` are used by some ingest
    /// servers. The sanitizer recognises several parameter names.
    func testSanitizeUrlWithQueryParamKey() {
        let input    = "rtmp://host/app?key=secret123"
        let expected = "rtmp://host/app?key=[REDACTED]"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "'key' query parameter value should be redacted"
        )
    }

    /// `token` is another common parameter name for auth credentials.
    func testSanitizeUrlWithQueryParamToken() {
        let input    = "rtmp://host/app?token=abc"
        let expected = "rtmp://host/app?token=[REDACTED]"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "'token' query parameter value should be redacted"
        )
    }

    /// `password` can appear as a query parameter in some setups.
    func testSanitizeUrlWithQueryParamPassword() {
        let input    = "rtmp://host/app?password=abc"
        let expected = "rtmp://host/app?password=[REDACTED]"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "'password' query parameter value should be redacted"
        )
    }

    /// `secret` is yet another sensitive parameter name.
    func testSanitizeUrlWithQueryParamSecret() {
        let input    = "rtmp://host/app?secret=myvalue"
        let expected = "rtmp://host/app?secret=[REDACTED]"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "'secret' query parameter value should be redacted"
        )
    }

    /// Verify that `passphrase=` is NOT currently redacted.
    /// SRT uses `passphrase` for encryption, but it is not in the
    /// sanitizer's list of known parameter names yet.
    /// This test documents the current gap — if the pattern is
    /// updated in the future, update this test accordingly.
    func testSanitizeSRTPassphraseNotCurrentlyCovered() {
        let input = "srt://host:9000?passphrase=mysecret"

        // "passphrase" is NOT in the query-param keyword list, so
        // the value will pass through unchanged for now.
        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            input,
            "passphrase= is not yet recognised — document the gap"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - URL Userinfo (user:password@host)
    // ---------------------------------------------------------------

    /// Some RTMP URLs embed credentials in the userinfo section:
    ///   rtmp://user:password@host/app
    /// The sanitizer should keep the username but redact the password.
    func testSanitizeUrlUserinfo() {
        let input    = "rtmp://user:mypass@host/app"
        let expected = "rtmp://user:[REDACTED]@host/app"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "Password in URL userinfo section should be redacted"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - JSON Credential Key-Value Pairs
    // ---------------------------------------------------------------

    /// Crash reports sometimes include JSON blobs. If a JSON key is
    /// a known credential name, its value should be redacted.
    func testSanitizeJsonCredentials() {
        let input    = #"{"password": "s3cret"}"#
        let expected = #"{"password": "[REDACTED]"}"#

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "JSON password values should be redacted"
        )
    }

    /// Test another JSON key: `stream_key`.
    func testSanitizeJsonStreamKey() {
        let input    = #"{"stream_key": "live_abc_123"}"#
        let expected = #"{"stream_key": "[REDACTED]"}"#

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "JSON stream_key values should be redacted"
        )
    }

    /// Test JSON key: `token`.
    func testSanitizeJsonToken() {
        let input    = #"{"token": "eyJhbGciOi"}"#
        let expected = #"{"token": "[REDACTED]"}"#

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "JSON token values should be redacted"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - Multiple Credentials in One String
    // ---------------------------------------------------------------

    /// A single string might contain more than one credential pattern.
    /// For example, a log line could mention an RTMP URL *and* query
    /// parameters. Both should be redacted in one pass.
    func testSanitizeMultipleCredentialsInOneString() {
        // This string has a query-param credential and a JSON credential.
        let input    = #"URL key=secret123 and config {"password": "s3cret"}"#
        let expected = #"URL key=[REDACTED] and config {"password": "[REDACTED]"}"#

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            expected,
            "All credential patterns in the same string should be redacted"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - Dictionary Sanitization
    // ---------------------------------------------------------------

    /// `sanitizeDictionary` should recursively clean every string
    /// value in a dictionary — including nested dictionaries.
    func testSanitizeDictionary() {
        let input: [String: Any] = [
            // A top-level string with a stream key URL
            "url": "rtmp://host/app/sk_live_key123",
            // A nested dictionary with a JSON-style credential
            "meta": [
                "config": #"{"password": "abc"}"#
            ] as [String: Any],
            // A non-string value should pass through unchanged
            "retryCount": 3
        ]

        let result = CredentialSanitizer.sanitizeDictionary(input)

        // Verify the top-level string was sanitized
        XCTAssertEqual(
            result["url"] as? String,
            "rtmp://host/app/[REDACTED]",
            "Top-level string values should be sanitized"
        )

        // Verify the nested dictionary string was sanitized
        let meta = result["meta"] as? [String: Any]
        XCTAssertEqual(
            meta?["config"] as? String,
            #"{"password": "[REDACTED]"}"#,
            "Nested dictionary string values should also be sanitized"
        )

        // Verify non-string values are left alone
        XCTAssertEqual(
            result["retryCount"] as? Int,
            3,
            "Non-string values (like Int) should pass through unchanged"
        )
    }

    /// Arrays inside dictionaries should also have their string
    /// elements sanitized.
    func testSanitizeDictionaryWithArray() {
        let input: [String: Any] = [
            "urls": [
                "rtmp://host/app/secret_key_1",
                "rtmp://host/app/secret_key_2"
            ]
        ]

        let result = CredentialSanitizer.sanitizeDictionary(input)
        let urls = result["urls"] as? [String]

        XCTAssertEqual(urls?.count, 2, "Array should still have 2 elements")
        XCTAssertEqual(
            urls?[0],
            "rtmp://host/app/[REDACTED]",
            "First array element should be sanitized"
        )
        XCTAssertEqual(
            urls?[1],
            "rtmp://host/app/[REDACTED]",
            "Second array element should be sanitized"
        )
    }

    // ---------------------------------------------------------------
    // MARK: - No False Positives (Negative Tests)
    // ---------------------------------------------------------------
    // These tests make sure the sanitizer does NOT modify strings
    // that don't contain credentials. A sanitizer that replaces too
    // much is almost as bad as one that replaces too little.

    /// Plain English text should pass through completely unchanged.
    func testSanitizePlainTextIsUnchanged() {
        let input = "Hello world"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            input,
            "Plain text without credentials must not be modified"
        )
    }

    /// An empty string should remain empty — no crashes, no junk text.
    func testSanitizeEmptyString() {
        XCTAssertEqual(
            CredentialSanitizer.sanitize(""),
            "",
            "Empty input must produce empty output"
        )
    }

    /// A normal HTTPS webpage URL (no stream key, no credentials)
    /// should not be redacted. The sanitizer should only target
    /// RTMP/RTMPS schemes for stream key removal.
    func testSanitizeDoesNotRedactNonSensitiveUrls() {
        let input = "https://example.com/page"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            input,
            "Non-RTMP URLs without credential params should be left alone"
        )
    }

    /// A URL with a query parameter that is NOT a known credential
    /// name should pass through unchanged.
    func testSanitizeDoesNotRedactNonSensitiveQueryParams() {
        let input = "https://example.com/search?q=hello&page=2"

        XCTAssertEqual(
            CredentialSanitizer.sanitize(input),
            input,
            "Query params like 'q' and 'page' are not sensitive"
        )
    }
}
