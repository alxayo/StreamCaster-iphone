import XCTest
@testable import StreamCaster

// ---------------------------------------------------------------------------
// EndpointProfileTests
// ---------------------------------------------------------------------------
// Tests for EndpointProfile (Identifiable, Codable, Equatable) defined in
// EndpointProfile.swift. An endpoint profile stores the RTMP server details
// a user needs to go live (URL, stream key, optional credentials).
// ---------------------------------------------------------------------------

final class EndpointProfileTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fully-populated profile for reuse across tests.
    /// Using a helper avoids duplicating long initializers in every test.
    private func makeProfile(
        id: String = "test-id",
        name: String = "My Stream",
        rtmpUrl: String = "rtmp://live.example.com/app",
        streamKey: String = "sk-abc123",
        username: String? = "user",
        password: String? = "pass",
        isDefault: Bool = false
    ) -> EndpointProfile {
        EndpointProfile(
            id: id,
            name: name,
            rtmpUrl: rtmpUrl,
            streamKey: streamKey,
            username: username,
            password: password,
            isDefault: isDefault
        )
    }

    // MARK: - Creation

    /// Verify that all fields are stored correctly after initialization.
    /// This is the most basic test — if it fails, nothing else matters.
    func testEndpointProfileCreationWithAllFields() {
        let profile = makeProfile(
            id: "abc-123",
            name: "Twitch",
            rtmpUrl: "rtmp://live.twitch.tv/app",
            streamKey: "live_abc123",
            username: "streamer",
            password: "s3cret",
            isDefault: true
        )

        XCTAssertEqual(profile.id, "abc-123")
        XCTAssertEqual(profile.name, "Twitch")
        XCTAssertEqual(profile.rtmpUrl, "rtmp://live.twitch.tv/app")
        XCTAssertEqual(profile.streamKey, "live_abc123")
        XCTAssertEqual(profile.username, "streamer")
        XCTAssertEqual(profile.password, "s3cret")
        XCTAssertTrue(profile.isDefault)
    }

    /// `isDefault` should be `false` when not explicitly set.
    /// Only one profile should ever be the default, so the safe fallback is false.
    func testEndpointProfileIsDefaultDefaultsToFalse() {
        let profile = EndpointProfile(
            id: "id",
            name: "name",
            rtmpUrl: "rtmp://example.com",
            streamKey: "key"
        )
        XCTAssertFalse(profile.isDefault,
                       "isDefault must be false when not provided")
    }

    /// Optional fields (username, password) should be nil when omitted.
    /// Many RTMP servers don't use credentials, so nil is the common case.
    func testEndpointProfileOptionalFieldsDefaultToNil() {
        let profile = EndpointProfile(
            id: "id",
            name: "name",
            rtmpUrl: "rtmp://example.com",
            streamKey: "key"
        )
        XCTAssertNil(profile.username, "username should be nil when omitted")
        XCTAssertNil(profile.password, "password should be nil when omitted")
    }

    // MARK: - Identifiable

    /// `EndpointProfile` conforms to `Identifiable` via its `id` property.
    /// SwiftUI uses this to track profiles in a List without extra work.
    func testEndpointProfileIdentifiableId() {
        let profile = makeProfile(id: "unique-42")
        // The `id` property required by `Identifiable` should match.
        XCTAssertEqual(profile.id, "unique-42")
    }

    /// Each profile created with UUID().uuidString has a unique id.
    /// This ensures profiles never collide when the user adds new ones.
    func testEndpointProfileIdUniquenessWithUUID() {
        let a = makeProfile(id: UUID().uuidString)
        let b = makeProfile(id: UUID().uuidString)
        XCTAssertNotEqual(a.id, b.id,
                          "Two UUIDs should virtually never collide")
    }

    // MARK: - Equatable

    /// Two profiles with identical fields are equal.
    /// The profile list uses equality to detect changes.
    func testEndpointProfileEqualitySameValues() {
        let a = makeProfile()
        let b = makeProfile()
        XCTAssertEqual(a, b)
    }

    /// Profiles with different IDs are not equal, even if everything else matches.
    func testEndpointProfileNotEqualDifferentId() {
        let a = makeProfile(id: "id-1")
        let b = makeProfile(id: "id-2")
        XCTAssertNotEqual(a, b)
    }

    /// Profiles with different names are not equal.
    func testEndpointProfileNotEqualDifferentName() {
        let a = makeProfile(name: "Twitch")
        let b = makeProfile(name: "YouTube")
        XCTAssertNotEqual(a, b)
    }

    /// Profiles with different RTMP URLs are not equal.
    func testEndpointProfileNotEqualDifferentUrl() {
        let a = makeProfile(rtmpUrl: "rtmp://a.com/live")
        let b = makeProfile(rtmpUrl: "rtmp://b.com/live")
        XCTAssertNotEqual(a, b)
    }

    /// Profiles with different stream keys are not equal.
    func testEndpointProfileNotEqualDifferentStreamKey() {
        let a = makeProfile(streamKey: "key-1")
        let b = makeProfile(streamKey: "key-2")
        XCTAssertNotEqual(a, b)
    }

    /// Profiles with different optional username values are not equal.
    func testEndpointProfileNotEqualDifferentUsername() {
        let a = makeProfile(username: "alice")
        let b = makeProfile(username: "bob")
        XCTAssertNotEqual(a, b)
    }

    /// Profiles with different optional password values are not equal.
    func testEndpointProfileNotEqualDifferentPassword() {
        let a = makeProfile(password: "pass1")
        let b = makeProfile(password: "pass2")
        XCTAssertNotEqual(a, b)
    }

    /// A profile with nil username ≠ one with a username set.
    func testEndpointProfileNotEqualNilVsSetUsername() {
        let a = makeProfile(username: nil)
        let b = makeProfile(username: "user")
        XCTAssertNotEqual(a, b)
    }

    /// Different isDefault flags make profiles unequal.
    func testEndpointProfileNotEqualDifferentIsDefault() {
        let a = makeProfile(isDefault: false)
        let b = makeProfile(isDefault: true)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip

    /// Encode a fully-populated profile to JSON and decode it back.
    /// This is critical because profiles are saved to disk / iCloud.
    func testEndpointProfileCodableRoundTrip() throws {
        let original = makeProfile(
            id: "round-trip-id",
            name: "YouTube",
            rtmpUrl: "rtmp://a.rtmp.youtube.com/live2",
            streamKey: "yt-key-123",
            username: "broadcaster",
            password: "p@ss",
            isDefault: true
        )

        // Encode to JSON data.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // deterministic output
        let data = try encoder.encode(original)

        // Decode back into a new EndpointProfile.
        let decoded = try JSONDecoder().decode(EndpointProfile.self, from: data)

        // Every field must survive the round-trip.
        XCTAssertEqual(decoded, original,
                       "Profile should be identical after JSON encode → decode")
    }

    /// Encode a profile with nil optional fields and decode it back.
    /// JSON should handle missing keys gracefully (nil stays nil).
    func testEndpointProfileCodableRoundTripWithNilOptionals() throws {
        let original = EndpointProfile(
            id: "nil-test",
            name: "Custom",
            rtmpUrl: "rtmp://custom.server.com/live",
            streamKey: "custom-key"
            // username and password intentionally omitted → nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EndpointProfile.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.username, "username should remain nil after decoding")
        XCTAssertNil(decoded.password, "password should remain nil after decoding")
        XCTAssertFalse(decoded.isDefault, "isDefault should remain false after decoding")
    }

    /// Verify the JSON contains the expected keys.
    /// This guards against someone renaming a CodingKey by accident.
    func testEndpointProfileCodableJsonKeys() throws {
        let profile = makeProfile(
            id: "key-check",
            name: "Test",
            rtmpUrl: "rtmp://example.com",
            streamKey: "sk",
            username: "u",
            password: "p",
            isDefault: true
        )

        let data = try JSONEncoder().encode(profile)
        // Parse raw JSON into a dictionary so we can inspect key names.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)

        // Every stored property must appear as a key.
        // Note: computed properties (like `detectedProtocol`) are NOT encoded.
        let expectedKeys: Set<String> = [
            "id", "name", "rtmpUrl", "streamKey",
            "username", "password", "isDefault",
            "videoCodec", "srtKeyLength",
            "srtMode", "srtLatencyMs",
            // srtPassphrase and srtStreamId are nil → omitted from JSON
        ]
        let actualKeys = Set(json?.keys ?? [String: Any]().keys)
        XCTAssertEqual(actualKeys, expectedKeys,
                       "JSON keys should match EndpointProfile properties")
    }

    // MARK: - Mutability

    /// `name`, `rtmpUrl`, `streamKey`, `username`, `password`, and `isDefault`
    /// are declared as `var` so the user can edit them in-place.
    /// `id` is `let` — it must never change after creation.
    func testEndpointProfileMutableFields() {
        var profile = makeProfile()

        profile.name = "Updated Name"
        profile.rtmpUrl = "rtmp://new.server.com/live"
        profile.streamKey = "new-key"
        profile.username = "new-user"
        profile.password = "new-pass"
        profile.isDefault = true

        XCTAssertEqual(profile.name, "Updated Name")
        XCTAssertEqual(profile.rtmpUrl, "rtmp://new.server.com/live")
        XCTAssertEqual(profile.streamKey, "new-key")
        XCTAssertEqual(profile.username, "new-user")
        XCTAssertEqual(profile.password, "new-pass")
        XCTAssertTrue(profile.isDefault)
    }

    /// The `id` field is immutable (`let`). Verify it stays the same even
    /// after mutating every other field.
    func testEndpointProfileIdIsImmutable() {
        var profile = makeProfile(id: "permanent-id")

        // Mutate everything we can.
        profile.name = "Changed"
        profile.rtmpUrl = "rtmp://changed.com"
        profile.streamKey = "changed-key"

        // `id` should still be the original value.
        XCTAssertEqual(profile.id, "permanent-id",
                       "The id must remain constant after mutation")
    }

    // MARK: - SRT Key Length Field

    /// New profiles should default to AES-256 encryption.
    /// This is the current industry standard for SRT encryption.
    func testEndpointProfileDefaultsSrtKeyLengthToAes256() {
        let profile = EndpointProfile(
            id: "id", name: "name",
            rtmpUrl: "srt://example.com", streamKey: "key"
        )
        XCTAssertEqual(profile.srtKeyLength, .aes256,
                       "Default SRT key length should be AES-256")
    }

    /// SRT key length should survive a JSON encode → decode round-trip.
    func testEndpointProfileCodableRoundTripWithSrtKeyLength() throws {
        let original = EndpointProfile(
            id: "srt-enc-test", name: "SRT Server",
            rtmpUrl: "srt://srt.example.com:9000",
            streamKey: "live",
            srtPassphrase: "mysecretpass1234",
            srtKeyLength: .aes128
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EndpointProfile.self, from: data)

        XCTAssertEqual(decoded.srtKeyLength, .aes128,
                       "srtKeyLength should survive JSON round-trip")
        XCTAssertEqual(decoded.srtPassphrase, "mysecretpass1234")
    }

    /// When JSON is missing the `srtKeyLength` key (e.g., data saved by
    /// an older version), decoding should default to `.aes256`.
    func testEndpointProfileDecodesLegacyJsonWithoutSrtKeyLength() throws {
        // JSON that an older app version would have written — no srtKeyLength key.
        let legacyJSON = """
        {
            "id": "legacy",
            "name": "Old Profile",
            "rtmpUrl": "srt://old.server.com:5000",
            "streamKey": "oldkey",
            "srtMode": "caller",
            "srtLatencyMs": 200,
            "srtPassphrase": "oldpassphrase1234",
            "isDefault": false,
            "videoCodec": "h264"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(EndpointProfile.self, from: legacyJSON)
        XCTAssertEqual(decoded.srtKeyLength, .aes256,
                       "Legacy JSON without srtKeyLength should default to AES-256")
    }
}
