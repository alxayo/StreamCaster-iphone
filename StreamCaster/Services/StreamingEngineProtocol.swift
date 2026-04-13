import Foundation
import Combine
import UIKit

// MARK: - StreamingEngineProtocol
/// The "brain" of the streaming system. Any class that conforms to this
/// protocol can start/stop an RTMP stream, manage the camera and microphone,
/// and publish real-time state updates.
///
/// View models talk to the engine exclusively through this protocol, which
/// makes it easy to swap in a mock for testing or a different streaming
/// library in the future.
@MainActor
protocol StreamingEngineProtocol: AnyObject {

    // MARK: Current State

    /// The latest snapshot of the entire session — connection status, media
    /// activity, background mode, and recording state, all in one struct.
    var sessionSnapshot: StreamSessionSnapshot { get }

    /// Real-time statistics like bitrate, FPS, dropped frames, and duration.
    var streamStats: StreamStats { get }

    // MARK: Publishers (Reactive Streams)

    /// Emits a new `StreamSessionSnapshot` every time any part of the
    /// session state changes. SwiftUI views or Combine pipelines can
    /// subscribe to this to stay in sync.
    var sessionSnapshotPublisher: AnyPublisher<StreamSessionSnapshot, Never> { get }

    /// Emits updated `StreamStats` roughly once per second while streaming.
    var streamStatsPublisher: AnyPublisher<StreamStats, Never> { get }

    // MARK: Stream Lifecycle

    /// Connect to the RTMP server for the given endpoint profile and start
    /// sending audio/video.
    /// - Parameter profileId: The `EndpointProfile.id` to stream to.
    func startStream(profileId: String) async throws

    /// Gracefully stop the stream.
    /// - Parameter reason: Why the stream is being stopped (user tap, error, etc.).
    func stopStream(reason: StopReason) async

    // MARK: Local Recording

    /// Start recording the live stream to a local MP4 file.
    ///
    /// The engine checks disk space, generates a timestamped filename, and
    /// tells the encoder bridge to begin writing frames. The recording state
    /// in the session snapshot is updated automatically.
    func startRecording() async

    /// Stop the current recording and finalize the MP4 file.
    ///
    /// The MP4 trailer is written so the file is playable, and the
    /// recording state returns to `.off`.
    func stopRecording() async

    // MARK: Media Controls

    /// Toggle the microphone mute on/off. When muted, silent audio frames
    /// are still sent so the RTMP connection stays alive.
    func toggleMute()

    /// Switch between the front and back camera.
    func switchCamera()

    /// Enable or disable individual media tracks mid-stream.
    /// - Parameters:
    ///   - videoEnabled: `true` to capture video, `false` to stop video capture.
    ///   - audioEnabled: `true` to capture audio, `false` to stop audio capture.
    func setMediaMode(videoEnabled: Bool, audioEnabled: Bool)

    // MARK: Preview

    /// Attach a UIView to display the live camera preview. The engine will
    /// add its preview layer as a sublayer of this view.
    /// - Parameter view: The UIView that should show the camera feed.
    func attachPreview(_ view: UIView)

    /// Remove the camera preview from whatever view it was previously
    /// attached to. Call this when the preview screen disappears.
    func detachPreview()
}
