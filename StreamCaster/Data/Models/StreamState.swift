import Foundation

// MARK: - TransportState
/// Represents the current state of the RTMP connection lifecycle.
/// Think of this as "what is the network connection doing right now?"
enum TransportState: Equatable {
    /// Not connected to any server — ready to start a new stream.
    case idle

    /// Actively trying to connect to the RTMP server (handshake in progress).
    case connecting

    /// Successfully connected and sending live audio/video data.
    case live

    /// Connection was lost; automatically retrying.
    /// - `attempt`: which retry attempt we are on (1, 2, 3 …)
    /// - `maxAttempts`: total number of retries configured (Int.max = unlimited)
    /// - `nextRetryMs`: milliseconds until the next retry fires
    case reconnecting(attempt: Int, maxAttempts: Int, nextRetryMs: Int64)

    /// Gracefully shutting down — flushing remaining data before disconnecting.
    case stopping

    /// Stream has ended. `reason` explains *why* it stopped.
    case stopped(reason: StopReason)
}

// MARK: - BackgroundState
/// Tracks whether the app is in the foreground, showing Picture-in-Picture,
/// or running in the background. iOS restricts what you can do in each state,
/// so the app needs to know which one it is in.
enum BackgroundState: Equatable {
    /// App is fully visible on screen — the normal state.
    case foreground

    /// Picture-in-Picture window is about to appear.
    case pipStarting

    /// Picture-in-Picture is showing the camera preview in a small overlay.
    case pipActive

    /// App moved to the background but is still streaming audio
    /// (video capture is paused to save battery).
    case backgroundAudioOnly

    /// App is fully suspended by iOS — no work is being done.
    case suspended
}

// MARK: - RecordingDestination
/// Where the local recording file should be saved on-device.
enum RecordingDestination: String, Codable, Equatable {
    /// Save into the user's Photos library (Camera Roll).
    case photosLibrary

    /// Save into the app's Documents folder (accessible via Files app).
    case documents
}

// MARK: - RecordingState
/// Tracks the status of local recording (saving a copy of the stream on-device).
enum RecordingState: Equatable {
    /// Local recording is turned off.
    case off

    /// Recording is being set up — file handle opened, encoder warming up.
    /// `destination` tells us where the file will go.
    case starting(destination: RecordingDestination)

    /// Actively writing frames to a local file at `destination`.
    case recording(destination: RecordingDestination)

    /// Recording has stopped capturing but is writing remaining data to disk.
    case finalizing

    /// Recording failed. `reason` is a human-readable description of what went wrong.
    case failed(reason: String)
}

// MARK: - InterruptionOrigin
/// Identifies *what* caused a media interruption — for example, a phone call
/// taking over the microphone or the camera becoming unavailable.
enum InterruptionOrigin: String, Codable, Equatable {
    /// No interruption — everything is normal.
    case none

    /// The iOS audio session was interrupted (e.g., incoming phone call).
    case audioSession

    /// The user dismissed the Picture-in-Picture window.
    case pipDismissed

    /// The camera hardware became unavailable (e.g., another app claimed it).
    case cameraUnavailable

    /// The app stopped receiving sample buffers from the capture pipeline.
    case sampleStall

    /// iOS reported high system pressure (thermal or memory).
    case systemPressure
}

// MARK: - MediaState
/// Tracks which media tracks (video and audio) are currently active and
/// whether the microphone is muted. Also records the most recent interruption.
struct MediaState: Equatable {
    /// `true` when the camera is capturing and encoding video frames.
    var videoActive: Bool = true

    /// `true` when the microphone is capturing and encoding audio samples.
    var audioActive: Bool = true

    /// `true` when the user has deliberately muted the microphone.
    /// Audio may still be *active* (capturing) but silent when muted.
    var audioMuted: Bool = false

    /// The most recent interruption that affected media capture.
    var interruptionOrigin: InterruptionOrigin = .none
}

// MARK: - StopReason
/// Explains *why* a stream was stopped. Each case maps to a different
/// recovery path or user-facing message.
enum StopReason: String, Codable, Equatable {
    /// The user tapped "Stop" intentionally.
    case userRequest

    /// The hardware video/audio encoder failed.
    case errorEncoder

    /// RTMP authentication failed (bad stream key or credentials).
    case errorAuth

    /// The camera could not be accessed or configured.
    case errorCamera

    /// Audio capture or encoding failed.
    case errorAudio

    /// Network connection was lost and all retry attempts were exhausted.
    case errorNetwork

    /// Ran out of disk space while recording locally.
    case errorStorage

    /// Device temperature reached a critical level — iOS forced a stop.
    case thermalCritical

    /// Battery dropped below the safety threshold.
    case batteryCritical

    /// PiP was dismissed while in video-only mode, so the stream ended.
    case pipDismissedVideoOnly

    /// iOS terminated the app (e.g., backgrounded too long).
    case osTerminated

    /// The reason could not be determined.
    case unknown
}

// MARK: - StreamSessionSnapshot
/// A complete, point-in-time snapshot of every aspect of a streaming session.
/// View models observe changes to this snapshot to update the UI.
struct StreamSessionSnapshot: Equatable {
    /// Current state of the RTMP network connection.
    var transport: TransportState

    /// Which media tracks are active and whether audio is muted.
    var media: MediaState

    /// Whether the app is in the foreground, PiP, or background.
    var background: BackgroundState

    /// Current local-recording status.
    var recording: RecordingState

    /// A convenient starting value: idle connection, all media active,
    /// foreground, no recording.
    static let idle = StreamSessionSnapshot(
        transport: .idle,
        media: MediaState(
            videoActive: true,
            audioActive: true,
            audioMuted: false,
            interruptionOrigin: .none
        ),
        background: .foreground,
        recording: .off
    )
}
