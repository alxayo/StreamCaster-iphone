import Foundation
import CoreImage

// MARK: - OverlayManager
/// An architectural hook for adding visual overlays on top of the camera
/// feed — things like a watermark, chat messages, or a "LIVE" badge.
///
/// Each video frame passes through `processFrame(_:)` before it is encoded.
/// The simplest implementation just returns the image unchanged; fancier
/// implementations can composite text, images, or animations on top.
protocol OverlayManager {

    /// Process a single video frame and optionally add overlays.
    /// - Parameter image: The raw camera frame as a Core Image object.
    /// - Returns: The (possibly modified) frame to send to the encoder.
    ///   Return the same `image` unchanged if no overlay is needed.
    func processFrame(_ image: CIImage) -> CIImage
}
