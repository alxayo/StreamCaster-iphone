import Foundation

// MARK: - CredentialSanitizer
/// CredentialSanitizer removes sensitive information from strings.
/// This prevents stream keys, passwords, and other secrets from
/// appearing in crash reports, logs, or diagnostics.
///
/// Why this matters:
///   When the app crashes or generates logs, those reports may be sent
///   to analytics services or stored on disk. If a stream key or password
///   is embedded in the text, it could be leaked. This sanitizer scans
///   for common credential patterns and replaces them with "[REDACTED]".
struct CredentialSanitizer {

    // MARK: - Constants

    /// The placeholder text that replaces any redacted content.
    /// Every sensitive value we find gets swapped out for this string.
    static let redactedPlaceholder = "[REDACTED]"

    // MARK: - Regex Patterns
    // We pre-compile all regex patterns once so we don't rebuild them
    // every time we sanitize a string. Each pattern targets a different
    // way credentials might appear in text.

    /// 1. RTMP URL stream keys
    /// Matches: rtmp://server/app/streamkey  or  rtmps://server/app/streamkey
    /// The stream key is the path segment after the app name.
    /// We keep the scheme + host + app and replace the key portion.
    private static let rtmpURLPattern: NSRegularExpression? = {
        // Breakdown:
        //   rtmps?://   – the RTMP scheme (with optional "s" for TLS)
        //   [^/]+       – the hostname (and optional port)
        //   /[^/]+      – the app name (first path segment)
        //   /(.+)       – everything after = the stream key (captured)
        try? NSRegularExpression(
            pattern: #"(rtmps?://[^/]+/[^/]+/)(.+)"#,
            options: .caseInsensitive
        )
    }()

    /// 2. Query-parameter credentials
    /// Matches key=value pairs where the key is a known secret name.
    /// For example: ?key=abc123&token=xyz  →  ?key=[REDACTED]&token=[REDACTED]
    private static let queryParamPattern: NSRegularExpression? = {
        // The key names we look for (case-insensitive):
        //   key, token, password, secret, auth, passwd, stream_key, streamkey
        try? NSRegularExpression(
            pattern: #"((?:key|token|password|secret|auth|passwd|stream_key|streamkey)\s*=\s*)([^&\s]+)"#,
            options: .caseInsensitive
        )
    }()

    /// 3. URL userinfo (user:password@host)
    /// Matches: ://user:password@host  →  ://user:[REDACTED]@host
    private static let userinfoPattern: NSRegularExpression? = {
        // Captures:
        //   Group 1: "://user:"   – the scheme separator, username, and colon
        //   Group 2: the password (everything up to the "@")
        //   Group 3: "@"          – the separator before the host
        try? NSRegularExpression(
            pattern: #"(://[^:]+:)([^@]+)(@)"#,
            options: []
        )
    }()

    /// 4. JSON-style key-value pairs with credential keys
    /// Matches: "password": "s3cret"  →  "password": "[REDACTED]"
    private static let jsonKeyValuePattern: NSRegularExpression? = {
        // Looks for a quoted key that is one of our known secret names,
        // followed by a colon and a quoted string value.
        try? NSRegularExpression(
            pattern: #"("(?:password|stream_key|streamKey|secret|token|auth_key)":\s*")([^"]*)"#,
            options: .caseInsensitive
        )
    }()

    /// 5. Base64-encoded tokens that look like credentials
    /// Matches long Base64 strings (40+ chars) that could be tokens or keys.
    /// This is a heuristic – it may not catch everything, but it covers
    /// common bearer tokens and API keys.
    private static let base64TokenPattern: NSRegularExpression? = {
        // Looks for strings of 40 or more Base64 characters (A-Z, a-z, 0-9, +, /)
        // optionally followed by "=" padding.
        try? NSRegularExpression(
            pattern: #"[A-Za-z0-9+/]{40,}={0,2}"#,
            options: []
        )
    }()

    // MARK: - Public API

    /// Sanitize a string by removing all known credential patterns.
    ///
    /// This is the main entry point. Pass any string (log message, URL,
    /// crash report field) and get back a version with secrets replaced.
    ///
    /// - Parameter input: The original string that might contain secrets.
    /// - Returns: A new string with all detected credentials replaced by `[REDACTED]`.
    static func sanitize(_ input: String) -> String {
        // We apply each pattern in sequence. The order matters slightly:
        // we do the more specific patterns first (RTMP URLs, JSON keys)
        // before the broader ones (Base64 tokens).
        var result = input

        // Step 1: Redact RTMP stream keys in URLs
        result = applyPattern(rtmpURLPattern, to: result, replacementTemplate: "$1\(redactedPlaceholder)")

        // Step 2: Redact query-parameter credentials
        result = applyPattern(queryParamPattern, to: result, replacementTemplate: "$1\(redactedPlaceholder)")

        // Step 3: Redact passwords in URL userinfo (user:pass@host)
        result = applyPattern(userinfoPattern, to: result, replacementTemplate: "$1\(redactedPlaceholder)$3")

        // Step 4: Redact JSON-style credential values
        result = applyPattern(jsonKeyValuePattern, to: result, replacementTemplate: "$1\(redactedPlaceholder)")

        // Step 5: Redact long Base64-encoded tokens
        result = applyPattern(base64TokenPattern, to: result, replacementTemplate: redactedPlaceholder)

        return result
    }

    /// Sanitize all string values in a dictionary.
    ///
    /// This is useful for cleaning crash report metadata or analytics
    /// payloads where multiple fields might contain secrets.
    ///
    /// - Parameter dict: A dictionary whose string values should be sanitized.
    /// - Returns: A new dictionary with all string values run through `sanitize(_:)`.
    static func sanitizeDictionary(_ dict: [String: Any]) -> [String: Any] {
        var cleaned = [String: Any]()

        for (key, value) in dict {
            switch value {
            // If the value is a plain string, sanitize it directly.
            case let stringValue as String:
                cleaned[key] = sanitize(stringValue)

            // If the value is a nested dictionary, recurse into it.
            case let nestedDict as [String: Any]:
                cleaned[key] = sanitizeDictionary(nestedDict)

            // If the value is an array, sanitize each element that is a string
            // or nested dictionary.
            case let array as [Any]:
                cleaned[key] = sanitizeArray(array)

            // For non-string, non-collection values (numbers, booleans, etc.)
            // just pass them through unchanged.
            default:
                cleaned[key] = value
            }
        }

        return cleaned
    }

    // MARK: - Private Helpers

    /// Apply a single regex pattern to a string, replacing matches with
    /// the given template. If the pattern is nil (failed to compile),
    /// we skip it and return the input unchanged.
    private static func applyPattern(
        _ pattern: NSRegularExpression?,
        to input: String,
        replacementTemplate: String
    ) -> String {
        guard let pattern = pattern else { return input }

        let range = NSRange(input.startIndex..., in: input)
        return pattern.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: replacementTemplate
        )
    }

    /// Sanitize each element in an array.
    /// Strings are sanitized, nested dictionaries are recursed into,
    /// and everything else passes through unchanged.
    private static func sanitizeArray(_ array: [Any]) -> [Any] {
        return array.map { element in
            switch element {
            case let stringValue as String:
                return sanitize(stringValue)
            case let nestedDict as [String: Any]:
                return sanitizeDictionary(nestedDict)
            case let nestedArray as [Any]:
                return sanitizeArray(nestedArray)
            default:
                return element
            }
        }
    }
}
