import XCTest
@testable import StreamCaster

// ---------------------------------------------------------------------------
// StreamStatsTests
// ---------------------------------------------------------------------------
// Tests for the real-time streaming statistics in StreamStats.swift:
//   • ThermalLevel – device temperature classification
//   • StreamStats  – live metrics shown in the UI (bitrate, FPS, etc.)
// ---------------------------------------------------------------------------

final class StreamStatsTests: XCTestCase {

    // MARK: - ThermalLevel — raw values

    /// `ThermalLevel` is `Codable` via its raw `String`.
    /// These raw values are sent to the analytics backend, so they must stay stable.
    func testThermalLevelRawValues() {
        XCTAssertEqual(ThermalLevel.normal.rawValue, "normal")
        XCTAssertEqual(ThermalLevel.fair.rawValue, "fair")
        XCTAssertEqual(ThermalLevel.serious.rawValue, "serious")
        XCTAssertEqual(ThermalLevel.critical.rawValue, "critical")
    }

    /// Round-trip every raw value to make sure no typo sneaks in.
    func testThermalLevelRoundTrip() {
        for level in [ThermalLevel.normal, .fair, .serious, .critical] {
            XCTAssertEqual(
                ThermalLevel(rawValue: level.rawValue), level,
                "\(level) did not round-trip through rawValue"
            )
        }
    }

    /// All four cases must exist. If a new level is added, this test reminds us.
    func testThermalLevelCaseCount() {
        let all: [ThermalLevel] = [.normal, .fair, .serious, .critical]
        XCTAssertEqual(all.count, 4,
                       "Update this test when adding new ThermalLevel cases")
    }

    /// An unknown raw value should return nil — not crash.
    func testThermalLevelUnknownRawValue() {
        XCTAssertNil(ThermalLevel(rawValue: "unknown"))
    }

    // MARK: - ThermalLevel — Codable round-trip

    /// Encode a ThermalLevel to JSON and decode it back.
    /// The streaming engine persists thermal history, so Codable must work.
    func testThermalLevelCodableRoundTrip() throws {
        let original = ThermalLevel.serious

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThermalLevel.self, from: data)

        XCTAssertEqual(decoded, original,
                       "ThermalLevel should survive a JSON encode → decode round-trip")
    }

    // MARK: - StreamStats — default values

    /// A freshly created `StreamStats` has all zeros / empty / normal.
    /// The UI shows these placeholders until real data arrives from the encoder.
    func testStreamStatsDefaultValues() {
        let stats = StreamStats()

        XCTAssertEqual(stats.videoBitrateKbps, 0,
                       "Video bitrate starts at 0 before the encoder reports")
        XCTAssertEqual(stats.audioBitrateKbps, 0,
                       "Audio bitrate starts at 0")
        XCTAssertEqual(stats.fps, 0,
                       "FPS starts at 0")
        XCTAssertEqual(stats.droppedFrames, 0,
                       "No frames dropped initially")
        XCTAssertEqual(stats.resolution, "",
                       "Resolution string is empty until the encoder starts")
        XCTAssertEqual(stats.durationMs, 0,
                       "Duration starts at 0")
        XCTAssertFalse(stats.isRecording,
                       "Not recording by default")
        XCTAssertEqual(stats.thermalLevel, .normal,
                       "Thermal level starts at normal")
    }

    // MARK: - StreamStats — equality

    /// Two default stats are equal.
    func testStreamStatsDefaultEquality() {
        XCTAssertEqual(StreamStats(), StreamStats())
    }

    /// Changing any single field should break equality.
    /// This is important because the UI diff-checks stats to avoid redundant updates.
    func testStreamStatsNotEqualWhenFieldDiffers() {
        let base = StreamStats()

        var diffBitrate = base
        diffBitrate.videoBitrateKbps = 2500
        XCTAssertNotEqual(base, diffBitrate)

        var diffAudioBitrate = base
        diffAudioBitrate.audioBitrateKbps = 128
        XCTAssertNotEqual(base, diffAudioBitrate)

        var diffFps = base
        diffFps.fps = 30
        XCTAssertNotEqual(base, diffFps)

        var diffDropped = base
        diffDropped.droppedFrames = 5
        XCTAssertNotEqual(base, diffDropped)

        var diffResolution = base
        diffResolution.resolution = "1280x720"
        XCTAssertNotEqual(base, diffResolution)

        var diffDuration = base
        diffDuration.durationMs = 60_000
        XCTAssertNotEqual(base, diffDuration)

        var diffRecording = base
        diffRecording.isRecording = true
        XCTAssertNotEqual(base, diffRecording)

        var diffThermal = base
        diffThermal.thermalLevel = .critical
        XCTAssertNotEqual(base, diffThermal)
    }

    /// Two stats with identical non-default values are equal.
    func testStreamStatsEqualityWithSameCustomValues() {
        var a = StreamStats()
        a.videoBitrateKbps = 2500
        a.audioBitrateKbps = 128
        a.fps = 29.97
        a.droppedFrames = 10
        a.resolution = "1280x720"
        a.durationMs = 120_000
        a.isRecording = true
        a.thermalLevel = .fair

        var b = StreamStats()
        b.videoBitrateKbps = 2500
        b.audioBitrateKbps = 128
        b.fps = 29.97
        b.droppedFrames = 10
        b.resolution = "1280x720"
        b.durationMs = 120_000
        b.isRecording = true
        b.thermalLevel = .fair

        XCTAssertEqual(a, b)
    }

    // MARK: - StreamStats — realistic scenario

    /// Simulate what stats look like during a healthy live stream.
    /// This verifies that all fields can hold realistic production values.
    func testStreamStatsRealisticValues() {
        var stats = StreamStats()
        stats.videoBitrateKbps = 2500
        stats.audioBitrateKbps = 128
        stats.fps = 30.0
        stats.droppedFrames = 0
        stats.resolution = "1280x720"
        stats.durationMs = 3_600_000   // 1 hour
        stats.isRecording = false
        stats.thermalLevel = .normal

        XCTAssertEqual(stats.videoBitrateKbps, 2500)
        XCTAssertEqual(stats.audioBitrateKbps, 128)
        XCTAssertEqual(stats.fps, 30.0, accuracy: 0.01)
        XCTAssertEqual(stats.droppedFrames, 0)
        XCTAssertEqual(stats.resolution, "1280x720")
        XCTAssertEqual(stats.durationMs, 3_600_000)
        XCTAssertFalse(stats.isRecording)
        XCTAssertEqual(stats.thermalLevel, .normal)
    }

    /// Simulate a degraded stream with thermal throttling.
    func testStreamStatsDegradedStream() {
        var stats = StreamStats()
        stats.videoBitrateKbps = 800    // ABR lowered the bitrate
        stats.fps = 15.0                // Halved for thermal relief
        stats.droppedFrames = 142       // Significant frame loss
        stats.thermalLevel = .serious

        XCTAssertEqual(stats.videoBitrateKbps, 800)
        XCTAssertEqual(stats.fps, 15.0, accuracy: 0.01)
        XCTAssertEqual(stats.droppedFrames, 142)
        XCTAssertEqual(stats.thermalLevel, .serious)
    }
}
