import Foundation
import AVFoundation
import CoreMedia

// MARK: - StubEncoderBridge
/// A fake implementation of EncoderBridge used during development.
/// It doesn't actually encode or stream anything — it just pretends to,
/// logging each action to the console.
///
/// This lets us build and test the StreamingEngine's state machine
/// without needing a real camera, microphone, or RTMP server.
///
/// T-007b will replace this with a real HaishinKit implementation.
final class StubEncoderBridge: EncoderBridge {

    // MARK: - State

    /// Tracks whether we're "connected" (always fake in this stub).
    private(set) var isConnected: Bool = false

    /// Which camera position we're pretending to use.
    private var cameraPosition: AVCaptureDevice.Position = .back

    // MARK: - Camera

    /// Pretend to attach a camera. Just logs the action.
    func attachCamera(position: AVCaptureDevice.Position) {
        cameraPosition = position
        print("[StubEncoderBridge] attachCamera(\(position == .front ? "front" : "back"))")
    }

    /// Pretend to detach the camera.
    func detachCamera() {
        print("[StubEncoderBridge] detachCamera()")
    }

    // MARK: - Audio

    /// Pretend to attach the microphone.
    func attachAudio() {
        print("[StubEncoderBridge] attachAudio()")
    }

    /// Pretend to detach the microphone.
    func detachAudio() {
        print("[StubEncoderBridge] detachAudio()")
    }

    // MARK: - RTMP Connection

    /// Pretend to connect to an RTMP server. Immediately marks us as "connected".
    func connect(url: String, streamKey: String) {
        // Mask the stream key for safety — only show last 4 chars.
        let maskedKey = String(repeating: "*", count: max(0, streamKey.count - 4))
            + streamKey.suffix(4)
        print("[StubEncoderBridge] connect(url: \(url), key: \(maskedKey))")
        isConnected = true
    }

    /// Pretend to disconnect from the RTMP server.
    func disconnect() {
        print("[StubEncoderBridge] disconnect()")
        isConnected = false
    }

    // MARK: - Encoder Configuration

    /// Pretend to configure the video codec. Logs the selection but does nothing.
    func configureCodec(_ codec: VideoCodec) {
        print("[StubEncoderBridge] configureCodec(\(codec.displayName))")
    }

    /// Pretend to change the video bitrate.
    func setBitrate(_ kbps: Int) async throws {
        print("[StubEncoderBridge] setBitrate(\(kbps) kbps)")
    }

    /// Pretend to update the full set of video encoding parameters.
    func setVideoSettings(resolution: Resolution, fps: Int, bitrateKbps: Int) async throws {
        print("[StubEncoderBridge] setVideoSettings(\(resolution.description), \(fps)fps, \(bitrateKbps)kbps)")
    }

    /// Pretend to insert a keyframe.
    func requestKeyFrame() async {
        print("[StubEncoderBridge] requestKeyFrame()")
    }

    // MARK: - Sample Buffer Tap

    /// Store a reference to the tap (but we never actually call it in the stub).
    private var sampleBufferTap: SampleBufferTap?

    /// Register a sample buffer tap. In the stub, this is stored but never invoked.
    func registerSampleBufferTap(_ tap: @escaping SampleBufferTap) {
        sampleBufferTap = tap
        print("[StubEncoderBridge] registerSampleBufferTap()")
    }

    /// Clear the sample buffer tap.
    func clearSampleBufferTap() {
        sampleBufferTap = nil
        print("[StubEncoderBridge] clearSampleBufferTap()")
    }

    // MARK: - Cleanup

    /// Release all resources (in the stub, just reset state and log).
    func release() {
        isConnected = false
        sampleBufferTap = nil
        print("[StubEncoderBridge] release()")
    }
}
