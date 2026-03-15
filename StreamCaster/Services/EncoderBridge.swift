import Foundation
import AVFoundation
import CoreMedia

// MARK: - SampleBufferTap
/// A closure that receives raw video sample buffers straight from the camera.
/// This is used for local recording or overlay processing — the tap "taps
/// into" the video pipeline so you can save or modify frames.
typealias SampleBufferTap = (CMSampleBuffer) -> Void

// MARK: - EncoderBridge
/// Abstracts the low-level encoding and RTMP publishing library (HaishinKit).
/// The streaming engine talks to this protocol instead of directly to
/// HaishinKit, which means:
///   1. We can swap HaishinKit for another library without rewriting the engine.
///   2. We can create a mock for unit tests that doesn't need real hardware.
///
/// All "heavy" operations (connecting, changing bitrate) are `async` because
/// they involve hardware or network I/O.
protocol EncoderBridge: AnyObject {

    // MARK: Camera

    /// Start capturing video from the specified camera.
    /// - Parameter position: `.front` or `.back`.
    func attachCamera(position: AVCaptureDevice.Position)

    /// Stop video capture and release the camera hardware.
    func detachCamera()

    // MARK: Audio

    /// Start capturing audio from the microphone.
    func attachAudio()

    /// Stop audio capture and release the microphone.
    func detachAudio()

    // MARK: RTMP Connection

    /// Open an RTMP connection and begin publishing.
    /// - Parameters:
    ///   - url: The RTMP server URL (e.g., "rtmp://live.twitch.tv/app").
    ///   - streamKey: The secret key that authorizes this stream.
    func connect(url: String, streamKey: String)

    /// Close the RTMP connection gracefully.
    func disconnect()

    /// Whether the encoder is currently connected to the RTMP server.
    var isConnected: Bool { get }

    // MARK: Encoder Configuration

    /// Change the video bitrate on the fly (used by Adaptive Bitrate).
    /// - Parameter kbps: New bitrate in kilobits per second.
    /// - Throws: If the encoder rejects the new value.
    func setBitrate(_ kbps: Int) async throws

    /// Update the full set of video encoding parameters.
    /// - Parameters:
    ///   - resolution: New resolution (width × height).
    ///   - fps: New frames per second.
    ///   - bitrateKbps: New bitrate in kilobits per second.
    /// - Throws: If the encoder can't apply the settings.
    func setVideoSettings(resolution: Resolution, fps: Int, bitrateKbps: Int) async throws

    /// Ask the encoder to insert a keyframe (I-frame) as soon as possible.
    /// Useful after a reconnection so new viewers can start decoding immediately.
    func requestKeyFrame() async

    // MARK: Sample Buffer Tap

    /// Register a closure that receives every raw video sample buffer.
    /// Only one tap can be active at a time — calling this again replaces
    /// the previous tap.
    /// - Parameter tap: The closure to call with each `CMSampleBuffer`.
    func registerSampleBufferTap(_ tap: @escaping SampleBufferTap)

    /// Remove the currently registered sample buffer tap.
    func clearSampleBufferTap()

    // MARK: Cleanup

    /// Release all resources: stop capture, close connections, free encoders.
    /// Call this when the streaming engine is being torn down.
    func release()
}
