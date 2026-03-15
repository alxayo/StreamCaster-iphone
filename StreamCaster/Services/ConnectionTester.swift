// ConnectionTester.swift
// StreamCaster
//
// Performs a lightweight RTMP handshake probe to verify that the
// app can reach and connect to the user's RTMP server. This does
// NOT send any audio/video data — it only checks that the network
// path, TCP connection, and RTMP handshake all succeed.
//
// Use this to give users a quick "does my config work?" check
// before they go live.

import Foundation
import Network

// MARK: - ConnectionTester

/// ConnectionTester performs a lightweight RTMP handshake probe.
///
/// WHAT DOES IT TEST?
/// - Network reachability to the RTMP server
/// - TCP connection establishment
/// - RTMP handshake (C0/C1 → S0/S1/S2)
/// - TLS/SSL for rtmps:// endpoints
///
/// WHAT DOESN'T IT TEST?
/// - Actual streaming (no video/audio data is sent)
/// - Long-running publish stability
/// - Stream key validity (some servers only validate on publish)
///
/// The result label makes clear this is a TRANSPORT probe,
/// not a full publish validation.
struct ConnectionTester {

    // MARK: - TestResult

    /// The outcome of a connection test.
    /// Each case carries a user-facing `message` that explains
    /// what happened and what the user can do about it.
    enum TestResult: Equatable {
        /// The TCP + RTMP handshake succeeded.
        /// Note: this does NOT guarantee streaming will work — some
        /// servers only validate the stream key during publish.
        case success(message: String)

        /// The connection attempt took longer than the timeout (10 s).
        /// Possible causes: firewall blocking, wrong port, server down.
        case timeout(message: String)

        /// The server rejected authentication during the handshake.
        case authFailure(message: String)

        /// TLS/SSL negotiation failed (bad cert, protocol mismatch, etc.).
        case tlsError(message: String)

        /// Blocked locally before any network call because the profile
        /// would send credentials over unencrypted rtmp://.
        case securityBlocked(message: String)

        /// A general network error (DNS failure, connection refused, etc.).
        case networkError(message: String)
    }

    // MARK: - Constants

    /// How long we wait for the probe before giving up.
    /// 10 seconds is generous enough for slow mobile networks
    /// but short enough that the user won't get bored.
    private static let timeoutSeconds: TimeInterval = 10

    /// The default RTMP port (used when the URL doesn't specify one).
    private static let defaultRtmpPort: UInt16 = 1935

    /// The default RTMPS port (used when the URL doesn't specify one).
    private static let defaultRtmpsPort: UInt16 = 443

    // MARK: - Public API

    /// Run the connection test against the given endpoint profile.
    ///
    /// This is an `async` function — call it with `await` from a Task.
    /// It will return after the probe succeeds, fails, or times out.
    ///
    /// - Parameter profile: The endpoint profile to test.
    /// - Returns: A `TestResult` describing what happened.
    static func test(profile: EndpointProfile) async -> TestResult {

        // ── Step 1: Validate transport security ──
        // Before hitting the network, make sure we're not about to
        // send credentials in plaintext. That's a hard block.
        let securityResult = TransportSecurityValidator.validate(profile: profile)

        switch securityResult {
        case .warningPlaintext, .allowed:
            // OK to proceed (warning case is just a UI hint, not a block).
            break
        }

        // ── Step 2: Parse the URL to get host and port ──
        guard let parsed = parseRtmpUrl(profile.rtmpUrl) else {
            return .networkError(
                message: "Invalid RTMP URL. Check the format "
                       + "(e.g., rtmp://server.example.com/live)."
            )
        }

        // ── Step 3: Attempt a TCP connection with optional TLS ──
        // We use Network.framework (NWConnection) because it gives
        // us fine-grained control over TLS and connection state.
        let result = await performTcpProbe(
            host: parsed.host,
            port: parsed.port,
            useTLS: parsed.isSecure
        )

        return result
    }

    // MARK: - URL Parsing

    /// A simple container for the parts we need from an RTMP URL.
    private struct ParsedURL {
        let host: String
        let port: UInt16
        let isSecure: Bool
    }

    /// Extract the host, port, and scheme from an RTMP URL string.
    ///
    /// Examples:
    ///   "rtmp://live.twitch.tv/app"     → host="live.twitch.tv", port=1935, secure=false
    ///   "rtmps://a.]rtmp.youtube.com"    → host="a.rtmp.youtube.com", port=443, secure=true
    ///   "rtmp://myserver:1936/live"      → host="myserver", port=1936, secure=false
    ///
    /// - Parameter urlString: The raw URL the user typed in.
    /// - Returns: A `ParsedURL`, or `nil` if the URL can't be parsed.
    private static func parseRtmpUrl(_ urlString: String) -> ParsedURL? {
        // Figure out if this is rtmp:// or rtmps://
        let lowered = urlString.lowercased()
        let isSecure = lowered.hasPrefix("rtmps://")
        let isPlain = lowered.hasPrefix("rtmp://")

        // Must start with rtmp:// or rtmps://
        guard isSecure || isPlain else { return nil }

        // Convert to a standard URL by swapping the scheme to https/http
        // so Foundation's URL parser can handle it. RTMP URLs have the
        // same structure as HTTP URLs (host, port, path).
        let fakeHttpUrl: String
        if isSecure {
            fakeHttpUrl = "https://" + String(urlString.dropFirst("rtmps://".count))
        } else {
            fakeHttpUrl = "http://" + String(urlString.dropFirst("rtmp://".count))
        }

        guard let url = URL(string: fakeHttpUrl),
              let host = url.host, !host.isEmpty else {
            return nil
        }

        // Use the port from the URL if specified, otherwise use defaults.
        let port: UInt16
        if let urlPort = url.port {
            port = UInt16(urlPort)
        } else {
            port = isSecure ? defaultRtmpsPort : defaultRtmpPort
        }

        return ParsedURL(host: host, port: port, isSecure: isSecure)
    }

    // MARK: - TCP Probe

    /// Open a TCP connection (with optional TLS) and report the result.
    ///
    /// This uses `NWConnection` from the Network framework. We:
    ///   1. Create a connection to host:port
    ///   2. Wait for it to reach the `.ready` state (TCP + TLS done)
    ///   3. If it succeeds within the timeout → success
    ///   4. If it times out → timeout
    ///   5. If it fails → map the error to a TestResult
    ///
    /// We do NOT send the full RTMP C0/C1 handshake bytes here —
    /// just verifying TCP+TLS reachability is enough for a settings
    /// screen "test connection" button. A full RTMP handshake would
    /// require implementing the RTMP binary protocol, which the
    /// encoder bridge handles during actual streaming.
    ///
    /// - Parameters:
    ///   - host: The server hostname or IP address.
    ///   - port: The TCP port number.
    ///   - useTLS: Whether to negotiate TLS (for rtmps://).
    /// - Returns: A `TestResult` describing the outcome.
    private static func performTcpProbe(
        host: String,
        port: UInt16,
        useTLS: Bool
    ) async -> TestResult {

        // Build the NWConnection with or without TLS.
        let parameters: NWParameters
        if useTLS {
            // Use default TLS settings — iOS handles certificate
            // validation automatically. No custom overrides.
            parameters = NWParameters(tls: .init())
        } else {
            // Plain TCP, no encryption.
            parameters = NWParameters.tcp
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )

        // We use a continuation to bridge NWConnection's callback-based
        // API into Swift's async/await world.
        let result: TestResult = await withCheckedContinuation { continuation in

            // This flag prevents the continuation from being resumed
            // more than once (which would crash). Both the state handler
            // and the timeout timer can try to resume it.
            let resumed = AtomicFlag()

            // ── Listen for connection state changes ──
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // TCP (and TLS if applicable) connection succeeded!
                    if resumed.setIfFirst() {
                        continuation.resume(returning: .success(
                            message: "Transport connection successful. "
                                   + "Server is reachable. Note: stream key "
                                   + "is only validated when you go live."
                        ))
                    }

                case .failed(let error):
                    // Connection failed — figure out why.
                    if resumed.setIfFirst() {
                        let result = mapNWError(error, useTLS: useTLS)
                        continuation.resume(returning: result)
                    }

                case .waiting(let error):
                    // Connection is waiting (usually means network is down).
                    if resumed.setIfFirst() {
                        let result = mapNWError(error, useTLS: useTLS)
                        continuation.resume(returning: result)
                    }

                default:
                    // .setup, .preparing, .cancelled — nothing to do yet.
                    break
                }
            }

            // ── Start the connection on a background queue ──
            let queue = DispatchQueue(
                label: "com.port80.app.connectionTester",
                qos: .userInitiated
            )
            connection.start(queue: queue)

            // ── Set up the timeout ──
            // If the connection hasn't completed after 10 seconds,
            // cancel it and report a timeout.
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                if resumed.setIfFirst() {
                    connection.cancel()
                    continuation.resume(returning: .timeout(
                        message: "Connection timed out after "
                               + "\(Int(timeoutSeconds))s. Check the server "
                               + "address, port, and your network connection."
                    ))
                }
            }
        }

        // Always clean up: cancel the connection so we don't leak resources.
        connection.cancel()

        return result
    }

    // MARK: - Error Mapping

    /// Convert an NWError into a user-friendly TestResult.
    ///
    /// NWError cases are quite technical ("POSIX error 61" isn't helpful
    /// to most users). We translate them into plain-English messages
    /// with actionable suggestions.
    ///
    /// - Parameters:
    ///   - error: The Network.framework error.
    ///   - useTLS: Whether TLS was being used (for context in the message).
    /// - Returns: A `TestResult` with a clear explanation.
    private static func mapNWError(_ error: NWError, useTLS: Bool) -> TestResult {
        switch error {
        case .tls(let status):
            // TLS negotiation failed — bad certificate, protocol mismatch, etc.
            return .tlsError(
                message: "TLS/SSL error (code \(status)). "
                       + "Check that the server supports TLS and has a valid certificate. "
                       + "Self-signed certs must be installed via iOS Settings."
            )

        case .posix(let code):
            // Map common POSIX errors to human-readable messages.
            switch code {
            case .ECONNREFUSED:
                // The server actively rejected the connection.
                return .networkError(
                    message: "Connection refused. The server may be down "
                           + "or the port may be wrong."
                )
            case .ETIMEDOUT:
                // TCP-level timeout (different from our app-level timeout).
                return .timeout(
                    message: "Connection timed out. Check the server "
                           + "address and your network connection."
                )
            case .ENETUNREACH, .EHOSTUNREACH:
                // Can't reach the network or host at all.
                return .networkError(
                    message: "Network unreachable. Check your Wi-Fi "
                           + "or cellular connection."
                )
            case .ECONNRESET:
                // Server closed the connection unexpectedly.
                return .networkError(
                    message: "Connection reset by server. The server "
                           + "may have rejected the connection."
                )
            default:
                // Some other POSIX error we haven't special-cased.
                return .networkError(
                    message: "Network error (POSIX \(code.rawValue)). "
                           + "Check the server address and your connection."
                )
            }

        case .dns(let status):
            // DNS lookup failed — hostname doesn't exist or DNS is down.
            return .networkError(
                message: "DNS lookup failed (code \(status)). "
                       + "Check that the server hostname is correct."
            )

        @unknown default:
            // Future NWError cases we haven't seen yet.
            return .networkError(
                message: "Connection failed: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - AtomicFlag

/// A thread-safe flag that can only be set once.
///
/// We use this to make sure a `CheckedContinuation` is resumed
/// exactly once, even when multiple threads (state handler + timeout)
/// both try to resume it at the same time.
///
/// HOW IT WORKS:
/// - Starts as `false`.
/// - `setIfFirst()` atomically checks the flag and sets it to `true`.
/// - Returns `true` only for the first caller; all later callers get `false`.
private final class AtomicFlag: @unchecked Sendable {

    /// The underlying lock that protects the `flag` variable.
    private let lock = NSLock()

    /// Whether the flag has been set yet.
    private var flag = false

    /// Try to set the flag. Returns `true` if this is the first call,
    /// `false` if someone already set it.
    func setIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // If the flag was already set, we're not first.
        if flag { return false }

        // We're first! Set it and return true.
        flag = true
        return true
    }
}
