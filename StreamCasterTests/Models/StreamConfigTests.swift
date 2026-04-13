import XCTest
@testable import StreamCaster

// ---------------------------------------------------------------------------
// StreamConfigTests
// ---------------------------------------------------------------------------
// Tests for the video/audio configuration models in StreamConfig.swift:
//   • Resolution  – width × height pair with a human-readable description
//   • StreamConfig – all the knobs a user can adjust before going live
// ---------------------------------------------------------------------------

final class StreamConfigTests: XCTestCase {

    // MARK: - Resolution — description

    /// The description must be in "WIDTHxHEIGHT" format.
    /// This string appears in the UI status bar and in analytics events.
    func testResolutionDescriptionFormat() {
        let res = Resolution(width: 1280, height: 720)
        XCTAssertEqual(res.description, "1280x720")
    }

    /// Full HD resolution should produce "1920x1080".
    func testResolutionDescriptionFullHD() {
        let res = Resolution(width: 1920, height: 1080)
        XCTAssertEqual(res.description, "1920x1080")
    }

    /// SD resolution should also format correctly.
    func testResolutionDescriptionSD() {
        let res = Resolution(width: 854, height: 480)
        XCTAssertEqual(res.description, "854x480")
    }

    /// Edge case: zero dimensions. The model doesn't forbid it,
    /// so description should still produce a valid string "0x0".
    func testResolutionDescriptionZeroDimensions() {
        let res = Resolution(width: 0, height: 0)
        XCTAssertEqual(res.description, "0x0")
    }

    // MARK: - Resolution — equality

    /// Two resolutions with the same width and height must be equal.
    /// SwiftUI relies on Equatable to skip redundant re-renders.
    func testResolutionEqualitySameValues() {
        let a = Resolution(width: 1280, height: 720)
        let b = Resolution(width: 1280, height: 720)
        XCTAssertEqual(a, b)
    }

    /// Resolutions with different dimensions must NOT be equal.
    func testResolutionEqualityDifferentValues() {
        let hd = Resolution(width: 1280, height: 720)
        let fullHD = Resolution(width: 1920, height: 1080)
        XCTAssertNotEqual(hd, fullHD)
    }

    /// Only width differs — should not be equal.
    func testResolutionNotEqualDifferentWidth() {
        let a = Resolution(width: 1280, height: 720)
        let b = Resolution(width: 1920, height: 720)
        XCTAssertNotEqual(a, b)
    }

    /// Only height differs — should not be equal.
    func testResolutionNotEqualDifferentHeight() {
        let a = Resolution(width: 1280, height: 720)
        let b = Resolution(width: 1280, height: 1080)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Resolution — Codable round-trip

    /// Encode a Resolution to JSON and decode it back.
    /// Ensures persistence (e.g., saving user settings) works correctly.
    func testResolutionCodableRoundTrip() throws {
        let original = Resolution(width: 1280, height: 720)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Resolution.self, from: data)

        XCTAssertEqual(decoded, original,
                       "Resolution should survive a JSON encode → decode round-trip")
    }

    // MARK: - Resolution — Hashable

    /// Resolution conforms to Hashable so it can be used as a dictionary key
    /// or in a Set. Two equal resolutions must hash the same way.
    func testResolutionHashable() {
        let a = Resolution(width: 1280, height: 720)
        let b = Resolution(width: 1280, height: 720)
        XCTAssertEqual(a.hashValue, b.hashValue,
                       "Equal resolutions must have the same hash")
    }

    // MARK: - StreamConfig — default values

    /// StreamConfig's defaults match what most streamers expect out of the box:
    /// 720p, 30 fps, 2.5 Mbps video, 128 kbps audio, stereo, ABR on.
    /// Changing a default is a breaking change — this test will catch it.
    func testStreamConfigDefaultValues() {
        let config = StreamConfig(profileId: "test-profile")

        // Video defaults
        XCTAssertTrue(config.videoEnabled, "Video should be enabled by default")
        XCTAssertEqual(config.resolution, Resolution(width: 1280, height: 720),
                       "Default resolution should be 720p")
        XCTAssertEqual(config.fps, 30, "Default FPS should be 30")
        XCTAssertEqual(config.videoBitrateKbps, 2500,
                       "Default video bitrate should be 2500 kbps")
        XCTAssertEqual(config.keyframeIntervalSec, 2,
                       "Keyframe interval should be 2 seconds by default")

        // Audio defaults
        XCTAssertTrue(config.audioEnabled, "Audio should be enabled by default")
        XCTAssertEqual(config.audioBitrateKbps, 128,
                       "Default audio bitrate should be 128 kbps")
        XCTAssertEqual(config.audioSampleRate, 44100,
                       "Default sample rate should be 44100 Hz (CD quality)")
        XCTAssertTrue(config.stereo, "Stereo should be on by default")

        // Feature flags
        XCTAssertTrue(config.abrEnabled,
                      "Adaptive bitrate should be enabled by default")
        XCTAssertFalse(config.localRecordingEnabled,
                       "Local recording should be off by default")
        XCTAssertTrue(config.recordToPhotosLibrary,
                      "Default recording destination should be Photos library")
    }

    // MARK: - StreamConfig — profileId

    /// The profileId ties a config to an EndpointProfile.
    /// Verify it is stored correctly.
    func testStreamConfigStoresProfileId() {
        let config = StreamConfig(profileId: "my-twitch-profile")
        XCTAssertEqual(config.profileId, "my-twitch-profile")
    }

    // MARK: - StreamConfig — equality

    /// Two configs with identical values are equal.
    func testStreamConfigEqualitySameValues() {
        let a = StreamConfig(profileId: "p1")
        let b = StreamConfig(profileId: "p1")
        XCTAssertEqual(a, b)
    }

    /// Configs with different profileIds are not equal.
    func testStreamConfigNotEqualDifferentProfileId() {
        let a = StreamConfig(profileId: "p1")
        let b = StreamConfig(profileId: "p2")
        XCTAssertNotEqual(a, b)
    }

    /// Changing any single property should break equality.
    func testStreamConfigNotEqualWhenPropertyDiffers() {
        let base = StreamConfig(profileId: "p1")

        var diffFps = base
        diffFps.fps = 60
        XCTAssertNotEqual(base, diffFps, "Different FPS should not be equal")

        var diffBitrate = base
        diffBitrate.videoBitrateKbps = 5000
        XCTAssertNotEqual(base, diffBitrate, "Different bitrate should not be equal")

        var diffResolution = base
        diffResolution.resolution = Resolution(width: 1920, height: 1080)
        XCTAssertNotEqual(base, diffResolution, "Different resolution should not be equal")

        var diffStereo = base
        diffStereo.stereo = false
        XCTAssertNotEqual(base, diffStereo, "Different stereo flag should not be equal")

        var diffAbr = base
        diffAbr.abrEnabled = false
        XCTAssertNotEqual(base, diffAbr, "Different ABR flag should not be equal")
    }

    // MARK: - StreamConfig — custom values

    /// Verify that every parameter can be customized after init.
    /// This simulates a user changing settings in the UI.
    func testStreamConfigWithCustomValues() {
        var config = StreamConfig(profileId: "custom")
        config.videoEnabled = false
        config.audioEnabled = false
        config.resolution = Resolution(width: 1920, height: 1080)
        config.fps = 60
        config.videoBitrateKbps = 6000
        config.audioBitrateKbps = 320
        config.audioSampleRate = 48000
        config.stereo = false
        config.keyframeIntervalSec = 1
        config.abrEnabled = false
        config.localRecordingEnabled = true
        config.recordToPhotosLibrary = false

        XCTAssertFalse(config.videoEnabled)
        XCTAssertFalse(config.audioEnabled)
        XCTAssertEqual(config.resolution.description, "1920x1080")
        XCTAssertEqual(config.fps, 60)
        XCTAssertEqual(config.videoBitrateKbps, 6000)
        XCTAssertEqual(config.audioBitrateKbps, 320)
        XCTAssertEqual(config.audioSampleRate, 48000)
        XCTAssertFalse(config.stereo)
        XCTAssertEqual(config.keyframeIntervalSec, 1)
        XCTAssertFalse(config.abrEnabled)
        XCTAssertTrue(config.localRecordingEnabled)
        XCTAssertFalse(config.recordToPhotosLibrary)
    }
}
