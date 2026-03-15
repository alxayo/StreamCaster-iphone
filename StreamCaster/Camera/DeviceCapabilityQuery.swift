import Foundation
import AVFoundation

// MARK: - DeviceCapabilityQuery
/// Asks the hardware "what can you do?" — which cameras are available, what
/// resolutions and frame rates they support, and whether this device is
/// powerful enough for high-quality streaming.
///
/// Having this behind a protocol means unit tests can provide fake devices
/// instead of needing a real camera.
protocol DeviceCapabilityQuery {

    /// Returns the list of resolutions that a specific camera supports.
    /// - Parameter camera: `.front` or `.back`.
    /// - Returns: An array of `Resolution` values sorted from smallest to largest.
    func supportedResolutions(for camera: AVCaptureDevice.Position) -> [Resolution]

    /// Returns the frame rates available at a given resolution on a given camera.
    /// - Parameters:
    ///   - resolution: The desired resolution (e.g., 1280×720).
    ///   - camera: `.front` or `.back`.
    /// - Returns: An array of supported FPS values (e.g., [24, 30, 60]).
    func supportedFrameRates(for resolution: Resolution, camera: AVCaptureDevice.Position) -> [Int]

    /// Returns all camera positions physically present on this device.
    /// Most iPhones have `.front` and `.back`; some iPods may only have one.
    func availableCameras() -> [AVCaptureDevice.Position]

    /// A quick check for whether this device is considered "Tier 1" (flagship).
    /// Tier 1 devices can handle 1080p60 + local recording simultaneously.
    /// Older or lower-end devices should default to lower settings.
    func isTier1Device() -> Bool
}
