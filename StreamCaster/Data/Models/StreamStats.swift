import Foundation

// MARK: - ThermalLevel
/// Maps to iOS thermal states. The device gets progressively hotter under
/// heavy workloads; the app should reduce quality at higher levels.
enum ThermalLevel: String, Codable {
    /// Device is cool — full performance available.
    case normal

    /// Slightly warm — no action needed yet, but worth monitoring.
    case fair

    /// Hot — the app should reduce bitrate or frame rate to cool down.
    case serious

    /// Critically hot — iOS may throttle the CPU/GPU or kill the app.
    /// The app should stop recording and lower quality immediately.
    case critical
}

// MARK: - StreamStats
/// Real-time statistics about the ongoing stream. Updated every second or so
/// and displayed to the user so they can monitor stream health.
struct StreamStats: Equatable {
    /// Current video bitrate in kilobits per second (e.g., 2500 = 2.5 Mbps).
    var videoBitrateKbps: Int = 0

    /// Current audio bitrate in kilobits per second (e.g., 128).
    var audioBitrateKbps: Int = 0

    /// Frames per second currently being sent (e.g., 30.0).
    var fps: Float = 0

    /// Total number of video frames that were dropped since the stream started.
    /// A high number here means the network or encoder can't keep up.
    var droppedFrames: Int64 = 0

    /// Human-readable resolution string (e.g., "1280x720").
    var resolution: String = ""

    /// How long the stream has been running, in milliseconds.
    var durationMs: Int64 = 0

    /// `true` when a local recording is also being written to disk.
    var isRecording: Bool = false

    /// Current thermal state of the device.
    var thermalLevel: ThermalLevel = .normal
}
