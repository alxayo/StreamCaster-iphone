import XCTest
@testable import StreamCaster

// ---------------------------------------------------------------------------
// SRTKeyLengthTests
// ---------------------------------------------------------------------------
// Tests for the `SRTKeyLength` enum defined in StreamProtocol.swift.
// SRTKeyLength represents the AES encryption key size for SRT connections:
// AES-128 (16 bytes), AES-192 (24 bytes), or AES-256 (32 bytes).
// ---------------------------------------------------------------------------

final class SRTKeyLengthTests: XCTestCase {

    // MARK: - pbKeyLenValue

    /// Verify that each case maps to the correct byte length for libsrt.
    /// libsrt's SRTO_PBKEYLEN expects exactly 16, 24, or 32.
    func testPbKeyLenValues() {
        XCTAssertEqual(SRTKeyLength.aes128.pbKeyLenValue, 16)
        XCTAssertEqual(SRTKeyLength.aes192.pbKeyLenValue, 24)
        XCTAssertEqual(SRTKeyLength.aes256.pbKeyLenValue, 32)
    }

    // MARK: - Display Names

    /// Verify human-readable display names for the settings UI.
    func testDisplayNames() {
        XCTAssertEqual(SRTKeyLength.aes128.displayName, "AES-128")
        XCTAssertEqual(SRTKeyLength.aes192.displayName, "AES-192")
        XCTAssertEqual(SRTKeyLength.aes256.displayName, "AES-256")
    }

    // MARK: - Subtitles

    /// Verify subtitle text exists and mentions bit count for each case.
    func testSubtitlesContainBitSize() {
        XCTAssertTrue(SRTKeyLength.aes128.subtitle.contains("128"))
        XCTAssertTrue(SRTKeyLength.aes192.subtitle.contains("192"))
        XCTAssertTrue(SRTKeyLength.aes256.subtitle.contains("256"))
    }

    // MARK: - CaseIterable

    /// There should be exactly 3 cases: AES-128, AES-192, AES-256.
    func testAllCasesCount() {
        XCTAssertEqual(SRTKeyLength.allCases.count, 3)
    }

    // MARK: - Codable

    /// Verify that the raw string value encodes/decodes correctly.
    /// This is important because the raw value is stored in user profiles.
    func testCodableRoundTrip() throws {
        for keyLength in SRTKeyLength.allCases {
            let data = try JSONEncoder().encode(keyLength)
            let decoded = try JSONDecoder().decode(SRTKeyLength.self, from: data)
            XCTAssertEqual(decoded, keyLength,
                           "\(keyLength) should survive JSON round-trip")
        }
    }

    /// Verify that raw string values match expected strings for persistence.
    func testRawValues() {
        XCTAssertEqual(SRTKeyLength.aes128.rawValue, "aes128")
        XCTAssertEqual(SRTKeyLength.aes192.rawValue, "aes192")
        XCTAssertEqual(SRTKeyLength.aes256.rawValue, "aes256")
    }
}
