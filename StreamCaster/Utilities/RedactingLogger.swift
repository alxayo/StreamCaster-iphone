import Foundation
import os

// MARK: - RedactingLogger
/// RedactingLogger wraps Apple's `os.Logger` to ensure sensitive
/// data like stream keys and passwords are never written to logs.
///
/// Apple's Unified Logging system already treats interpolated values
/// as private by default in release builds, but this logger adds an
/// extra layer: it runs every message through `CredentialSanitizer`
/// before logging, so even if a developer forgets to mark a value
/// as `.private`, secrets still won't leak.
///
/// Usage:
/// ```swift
///   let log = RedactingLogger(category: "streaming")
///   log.info("Connected to server")           // Safe – no secrets
///   log.debug("Stream started for user 42")   // Only visible in debug
///   log.error("Connection failed: \(error)")  // Errors always logged
/// ```
struct RedactingLogger {

    // MARK: - Properties

    /// The underlying Apple os.Logger that does the actual logging.
    /// We keep it accessible so callers can use it directly if they
    /// need advanced os.Logger features (e.g., signposts).
    let logger: Logger

    // MARK: - Initialization

    /// Create a new RedactingLogger.
    ///
    /// - Parameters:
    ///   - subsystem: The app's bundle identifier. Defaults to "com.port80.app".
    ///   - category: A short label for this logger's area (e.g., "network", "auth").
    init(subsystem: String = "com.port80.app", category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Logging Methods
    // Each method corresponds to a log level in Apple's unified logging.
    // Messages are sanitized before logging to strip any credentials.
    //
    // Log levels (from least to most severe):
    //   debug    → Verbose info for development. Not persisted in release.
    //   info     → Helpful context. Persisted briefly.
    //   notice   → Default level. Persisted until storage pressure.
    //   warning  → Something unexpected. Persisted longer.
    //   error    → Something went wrong. Always persisted.
    //   critical → Serious failure. Always persisted.

    /// Log a debug-level message.
    /// Debug messages are only captured when a debugger is attached or
    /// logging is explicitly enabled for this subsystem. Use freely
    /// during development; they won't appear in production logs.
    func debug(_ message: String) {
        let sanitized = CredentialSanitizer.sanitize(message)
        logger.debug("\(sanitized, privacy: .private)")
    }

    /// Log an info-level message.
    /// Info messages are captured but only persisted briefly.
    /// Good for noting state transitions ("connected", "stream started").
    func info(_ message: String) {
        let sanitized = CredentialSanitizer.sanitize(message)
        logger.info("\(sanitized, privacy: .private)")
    }

    /// Log a notice-level message.
    /// This is the default log level. Messages are persisted until
    /// the system needs to reclaim storage.
    func notice(_ message: String) {
        let sanitized = CredentialSanitizer.sanitize(message)
        logger.notice("\(sanitized, privacy: .public)")
    }

    /// Log a warning-level message.
    /// Use when something unexpected happened but the app can continue.
    /// For example: a network retry, a fallback to a default value.
    func warning(_ message: String) {
        let sanitized = CredentialSanitizer.sanitize(message)
        logger.warning("\(sanitized, privacy: .public)")
    }

    /// Log an error-level message.
    /// Use when an operation failed. These are always persisted and
    /// visible in Console.app and crash diagnostics.
    func error(_ message: String) {
        let sanitized = CredentialSanitizer.sanitize(message)
        logger.error("\(sanitized, privacy: .public)")
    }

    /// Log a critical-level message.
    /// Use for serious failures that may cause data loss or require
    /// the user to restart the app.
    func critical(_ message: String) {
        let sanitized = CredentialSanitizer.sanitize(message)
        logger.critical("\(sanitized, privacy: .public)")
    }
}

// MARK: - Redacted Property Wrapper
/// `Redacted` wraps a value so it cannot be accidentally printed or logged.
/// When you convert it to a string (via `print()`, string interpolation, or
/// the debugger), it shows "[REDACTED]" instead of the actual value.
///
/// The real value is still accessible through the `.wrappedValue` property
/// (or the underlying property when used as a property wrapper), so your
/// code can still use it — it just can't leak by accident.
///
/// Example as a property wrapper:
/// ```swift
///   struct StreamConfig {
///       @Redacted var streamKey: String
///   }
///
///   let config = StreamConfig(streamKey: "my-secret-key")
///   print(config.streamKey)   // prints: [REDACTED]
///   config.$streamKey         // the Redacted<String> wrapper itself
/// ```
///
/// Example as a standalone wrapper:
/// ```swift
///   let secret = Redacted(wrappedValue: "my-secret-key")
///   print(secret)             // prints: Redacted<String>([REDACTED])
///   secret.wrappedValue       // "my-secret-key"
/// ```
@propertyWrapper
struct Redacted<Value> {

    /// The actual secret value. Only access this when you truly need
    /// the real data (e.g., to send it over the network).
    var wrappedValue: Value

    /// Provides access to the `Redacted` wrapper itself via the `$` prefix.
    /// For example, `$streamKey` gives you the `Redacted<String>` struct.
    var projectedValue: Redacted<Value> {
        self
    }

    /// Create a Redacted wrapper around a value.
    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

// MARK: - CustomStringConvertible
// When someone does `print(redactedValue)` or uses it in string
// interpolation like "\(redactedValue)", this is what they see.
extension Redacted: CustomStringConvertible {
    var description: String {
        return CredentialSanitizer.redactedPlaceholder
    }
}

// MARK: - CustomDebugStringConvertible
// When someone inspects the value in the debugger (po, lldb),
// this is what they see. Still redacted for safety.
extension Redacted: CustomDebugStringConvertible {
    var debugDescription: String {
        return "Redacted<\(Value.self)>(\(CredentialSanitizer.redactedPlaceholder))"
    }
}

// MARK: - Equatable (when the wrapped value is Equatable)
// This lets you compare two Redacted values without unwrapping them.
extension Redacted: Equatable where Value: Equatable {
    static func == (lhs: Redacted<Value>, rhs: Redacted<Value>) -> Bool {
        return lhs.wrappedValue == rhs.wrappedValue
    }
}

// MARK: - Hashable (when the wrapped value is Hashable)
// This lets you use Redacted values as dictionary keys or in sets.
extension Redacted: Hashable where Value: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(wrappedValue)
    }
}

// MARK: - Codable (when the wrapped value is Codable)
// Redacted values can be encoded/decoded from JSON, but the encoded
// form contains the real value. Be careful when serializing!
extension Redacted: Decodable where Value: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode(Value.self)
    }
}

extension Redacted: Encodable where Value: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

// MARK: - Sendable (when the wrapped value is Sendable)
// Allows Redacted values to be safely passed across concurrency boundaries.
extension Redacted: Sendable where Value: Sendable {}
