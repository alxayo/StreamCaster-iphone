import XCTest
@testable import StreamCaster

// ---------------------------------------------------------------------------
// SRTURLBuilderTests
// ---------------------------------------------------------------------------
// Tests for `SRTEncoderBridge.buildSRTURL()` — the static method that
// assembles SRT connection URLs with query parameters for mode, latency,
// passphrase, pbkeylen, and stream ID.
// ---------------------------------------------------------------------------

final class SRTURLBuilderTests: XCTestCase {

    // MARK: - pbkeylen parameter

    /// When a passphrase is provided, `pbkeylen` should appear in the URL
    /// with the correct byte value for the requested AES key length.
    func testPbkeylenAppearsWhenPassphraseIsSet() {
        let url = SRTEncoderBridge.buildSRTURL(
            baseURL: "srt://server.com:9000",
            streamKey: "live",
            passphrase: "mysecretpass1234",
            pbKeyLen: 32  // AES-256
        )

        XCTAssertNotNil(url)
        let query = url!.query ?? ""
        XCTAssertTrue(query.contains("pbkeylen=32"),
                      "URL should contain pbkeylen=32 for AES-256. Got: \(query)")
    }

    /// AES-128 should produce `pbkeylen=16`.
    func testPbkeylen16ForAes128() {
        let url = SRTEncoderBridge.buildSRTURL(
            baseURL: "srt://server.com:9000",
            streamKey: "live",
            passphrase: "mysecretpass1234",
            pbKeyLen: 16  // AES-128
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.query!.contains("pbkeylen=16"),
                      "URL should contain pbkeylen=16 for AES-128")
    }

    /// AES-192 should produce `pbkeylen=24`.
    func testPbkeylen24ForAes192() {
        let url = SRTEncoderBridge.buildSRTURL(
            baseURL: "srt://server.com:9000",
            streamKey: "live",
            passphrase: "mysecretpass1234",
            pbKeyLen: 24  // AES-192
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.query!.contains("pbkeylen=24"),
                      "URL should contain pbkeylen=24 for AES-192")
    }

    /// When no passphrase is provided, `pbkeylen` should NOT appear.
    /// Without a passphrase there's no encryption, so key length is irrelevant.
    func testPbkeylenOmittedWhenNoPassphrase() {
        let url = SRTEncoderBridge.buildSRTURL(
            baseURL: "srt://server.com:9000",
            streamKey: "live",
            passphrase: nil,
            pbKeyLen: 32
        )

        XCTAssertNotNil(url)
        let query = url!.query ?? ""
        XCTAssertFalse(query.contains("pbkeylen"),
                       "URL should NOT contain pbkeylen when passphrase is nil. Got: \(query)")
    }

    /// When passphrase is empty, `pbkeylen` should NOT appear.
    func testPbkeylenOmittedWhenPassphraseEmpty() {
        let url = SRTEncoderBridge.buildSRTURL(
            baseURL: "srt://server.com:9000",
            streamKey: "live",
            passphrase: "",
            pbKeyLen: 32
        )

        XCTAssertNotNil(url)
        let query = url!.query ?? ""
        XCTAssertFalse(query.contains("pbkeylen"),
                       "URL should NOT contain pbkeylen when passphrase is empty. Got: \(query)")
    }

    /// If the base URL already contains `pbkeylen`, the builder should NOT
    /// add a duplicate. User-specified URL params always take priority.
    func testPbkeylenNotDuplicatedWhenAlreadyInUrl() {
        let url = SRTEncoderBridge.buildSRTURL(
            baseURL: "srt://server.com:9000?pbkeylen=16",
            streamKey: "live",
            passphrase: "mysecretpass1234",
            pbKeyLen: 32  // Would be 32, but URL already says 16
        )

        XCTAssertNotNil(url)
        let query = url!.query ?? ""
        // Count occurrences of "pbkeylen" — should be exactly 1.
        let count = query.components(separatedBy: "pbkeylen").count - 1
        XCTAssertEqual(count, 1,
                       "pbkeylen should appear exactly once. Got: \(query)")
        XCTAssertTrue(query.contains("pbkeylen=16"),
                      "URL's original pbkeylen=16 should be preserved")
    }

    // MARK: - Default pbKeyLen

    /// The default `pbKeyLen` parameter should be 32 (AES-256).
    func testDefaultPbKeyLenIs32() {
        let url = SRTEncoderBridge.buildSRTURL(
            baseURL: "srt://server.com:9000",
            streamKey: "live",
            passphrase: "mysecretpass1234"
            // pbKeyLen not specified — should default to 32
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.query!.contains("pbkeylen=32"),
                      "Default pbkeylen should be 32 (AES-256)")
    }
}
