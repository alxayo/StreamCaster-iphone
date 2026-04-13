import Foundation
import AVFoundation
import Combine
import CoreMedia
import UIKit

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

    /// Start capturing video from the specified camera device.
    /// - Parameter device: The `AVCaptureDevice` to use, or `nil` to detach.
    func attachCamera(device: AVCaptureDevice?) async

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

    /// Configure which video codec the encoder should use.
    ///
    /// This **must** be called before `connect(url:streamKey:)` because the
    /// underlying encoder (VideoToolbox) needs to know the codec type when
    /// creating the compression session.
    ///
    /// This method is `async` because the underlying VideoToolbox session
    /// setup can block. Callers must `await` it to avoid a race condition
    /// where `setVideoSettings()` runs before the codec change completes.
    ///
    /// - Parameter codec: The desired video codec (.h264, .h265, or .av1).
    ///   If the codec isn't available on this device (e.g., AV1 on older
    ///   hardware), the implementation should fall back to H.264.
    func configureCodec(_ codec: VideoCodec) async

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

    // MARK: Local Recording

    /// Start recording the stream to a local MP4 file.
    ///
    /// The recording captures the same audio and video frames being sent
    /// to the RTMP server, so there is minimal additional CPU or battery
    /// overhead — we're simply writing the already-encoded data to a
    /// second destination (a file instead of the network).
    ///
    /// - Parameter fileURL: The local file URL where the MP4 will be saved.
    ///   The file must **not** already exist, and the parent directory must
    ///   be writable.
    /// - Throws: If the file already exists, the format is unsupported, or
    ///   the underlying writer cannot be created.
    func startRecording(to fileURL: URL) async throws

    /// Stop the current recording and finalize the MP4 file.
    ///
    /// This flushes any buffered frames, writes the MP4 trailer (moov atom),
    /// and closes the file. The returned URL is the same one passed to
    /// `startRecording(to:)` — you can use it to move the file, share it,
    /// or save it to the Photos library.
    ///
    /// - Returns: The file URL of the finished recording.
    /// - Throws: If no recording is in progress or the writer fails to finalize.
    @discardableResult
    func stopRecording() async throws -> URL?

    /// Whether a local recording is currently in progress.
    ///
    /// This is `true` between a successful `startRecording(to:)` call and
    /// the completion of `stopRecording()`. Use it to guard UI state and
    /// prevent starting a second recording.
    var isRecording: Bool { get }

    // MARK: Preview

    /// Attach a UIView to display the live camera preview.
    ///
    /// The view should be an `MTHKView` (Metal-based HaishinKit view).
    /// The bridge adds it as an output of the media pipeline so it receives
    /// the same frames being encoded and sent to the server.
    ///
    /// - Parameter view: The UIView to render the camera preview into.
    func attachPreview(_ view: UIView)

    /// Remove the camera preview view from the media pipeline.
    /// Call this before swapping bridges or when the preview is no longer visible.
    func detachPreview()

    // MARK: SRT Configuration

    /// Configure SRT-specific connection options.
    ///
    /// These options are only meaningful for SRT connections. RTMP bridges
    /// should ignore this call (the default implementation is a no-op).
    ///
    /// - Parameters:
    ///   - mode: SRT connection mode (caller, listener, or rendezvous).
    ///   - passphrase: Optional AES encryption passphrase (10–79 characters).
    ///   - latencyMs: Buffer latency in milliseconds (default 120ms).
    ///   - streamId: Optional stream routing identifier.
    func configureSRTOptions(
        mode: SRTMode,
        passphrase: String?,
        latencyMs: Int,
        streamId: String?
    )

    // MARK: Stats

    /// Publishes live stream statistics (bitrate, fps, duration, etc.)
    /// roughly once per second while streaming.
    var statsPublisher: AnyPublisher<StreamStats, Never> { get }

    // MARK: Video Orientation

    /// Update the video capture orientation to match the device's physical
    /// orientation.
    ///
    /// Call this whenever the device rotates so the captured frames are
    /// oriented correctly. Under the hood this sets
    /// `AVCaptureConnection.videoOrientation` on the camera capture session.
    ///
    /// - Parameter orientation: The `AVCaptureVideoOrientation` that matches
    ///   the current device orientation.
    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation)

    // MARK: Video Stabilization

    /// Apply a video stabilization mode to the active camera connection.
    /// Call after `attachCamera(device:)` so a capture session exists.
    func setVideoStabilization(_ mode: AVCaptureVideoStabilizationMode)

    // MARK: Cleanup

    /// Release all resources: stop capture, close connections, free encoders.
    /// Call this when the streaming engine is being torn down.
    func release()
}

// MARK: - EncoderBridge Default Implementations

/// Default no-op implementations for methods that only apply to specific
/// bridge types. This avoids forcing every bridge to implement methods
/// that are irrelevant to their protocol (e.g., RTMP bridges don't need SRT config).
extension EncoderBridge {
    /// Default no-op for RTMP bridges — SRT options are irrelevant.
    func configureSRTOptions(
        mode: SRTMode,
        passphrase: String?,
        latencyMs: Int,
        streamId: String?
    ) {
        // No-op — only SRTEncoderBridge implements this.
    }

    /// Default no-op — only bridges with AVCaptureSession access implement this.
    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        // No-op by default.
    }

    /// Default no-op — only bridges with AVCaptureSession access implement this.
    func setVideoStabilization(_ mode: AVCaptureVideoStabilizationMode) {
        // No-op by default.
    }
}
