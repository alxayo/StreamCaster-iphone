import Foundation

// MARK: - VideoCodec
/// Represents the video codec used for encoding the live stream.
///
/// Different codecs trade off quality, bandwidth, and compatibility:
///   • H.264: Universal support, works with all RTMP servers. Default choice.
///   • H.265 (HEVC): ~40% better quality at the same bitrate as H.264.
///     Requires "Enhanced RTMP" server support. Available on all iPhones.
///   • AV1: ~50% better quality than H.264, but requires iPhone 15 Pro
///     or later (A17 Pro chip) for hardware encoding.
///
/// Not all codecs work with all protocols:
///   • RTMP/RTMPS: H.264, H.265, AV1 (H.265/AV1 need Enhanced RTMP)
///   • SRT: H.264, H.265 only (no AV1 over SRT)
enum VideoCodec: String, Codable, CaseIterable, Equatable {
    /// H.264 / AVC — the universal standard. Works everywhere.
    case h264 = "h264"

    /// H.265 / HEVC — better compression than H.264.
    /// Requires Enhanced RTMP server support.
    case h265 = "h265"

    /// AV1 — best compression, but requires:
    ///   1. A17 Pro chip or later (iPhone 15 Pro+) for hardware encoding
    ///   2. Enhanced RTMP server support
    ///   3. NOT supported over SRT protocol
    case av1 = "av1"

    /// Human-readable display name for the UI.
    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265 (HEVC)"
        case .av1: return "AV1"
        }
    }

    /// A short description of the codec for settings screens.
    var subtitle: String {
        switch self {
        case .h264: return "Universal compatibility"
        case .h265: return "Better quality, needs Enhanced RTMP"
        case .av1: return "Experimental — falls back to H.264"
        }
    }

    /// Whether this codec requires Enhanced RTMP server support.
    var requiresEnhancedRTMP: Bool {
        switch self {
        case .h264: return false
        case .h265, .av1: return true
        }
    }

    /// Whether this codec is supported over SRT protocol.
    var supportedOverSRT: Bool {
        switch self {
        case .h264, .h265: return true
        case .av1: return false
        }
    }

    /// Check if hardware encoding is available on this device for this codec.
    /// AV1 requires A17 Pro (iPhone 15 Pro) or later.
    /// H.264 and H.265 are available on all supported devices.
    var isHardwareEncodingAvailable: Bool {
        switch self {
        case .h264, .h265:
            return true
        case .av1:
            // AV1 hardware encoding requires A17 Pro or later.
            // We check by looking at the device model identifier.
            return Self.deviceSupportsAV1HardwareEncoding()
        }
    }

    /// Check if the current device has AV1 hardware encoding.
    /// A17 Pro (iPhone 15 Pro) and later chips support AV1 encoding.
    private static func deviceSupportsAV1HardwareEncoding() -> Bool {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }

        // iPhone 15 Pro = iPhone16,1; iPhone 15 Pro Max = iPhone16,2
        // iPhone 16 series = iPhone17,x
        // All future devices should also support AV1.
        // On simulators, always return true for testing.
        if identifier.hasPrefix("x86_64") || identifier.hasPrefix("arm64") {
            return true  // Simulator — assume supported for testing
        }

        // Parse the major version from "iPhoneXX,Y"
        guard identifier.hasPrefix("iPhone") else { return false }
        let versionPart = identifier.dropFirst(6) // Remove "iPhone"
        let parts = versionPart.split(separator: ",")
        guard let major = parts.first, let majorNum = Int(major) else { return false }

        // iPhone16,1+ = A17 Pro and later — supports AV1
        return majorNum >= 16
    }
}
