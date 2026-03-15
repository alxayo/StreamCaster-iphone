import CoreImage

/// NoOpOverlayManager is the default overlay implementation.
/// It does nothing to the video frames — just passes them through unchanged.
///
/// In the future, this can be replaced with an implementation that adds
/// text overlays, timestamps, watermarks, or other graphics on top of
/// the video before it's encoded and streamed.
///
/// This follows the "Strategy Pattern" — we define an interface (protocol)
/// and can swap implementations without changing the rest of the code.
final class NoOpOverlayManager: OverlayManager {
    func processFrame(_ image: CIImage) -> CIImage {
        // Simply return the image unchanged — no overlay applied
        return image
    }
}
