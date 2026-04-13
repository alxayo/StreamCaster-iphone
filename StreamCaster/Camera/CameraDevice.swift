import AVFoundation

// MARK: - CameraDevice
/// Identifies a specific camera on the device — not just "front" or "back",
/// but which *lens* (wide, ultra-wide, telephoto) on each side.
///
/// Modern iPhones have multiple rear cameras:
///   - Wide Angle (1×)      — available on all iPhones
///   - Ultra Wide (0.5×)    — iPhone 11+
///   - Telephoto (2×–5×)    — Pro models only
///
/// This model wraps AVCaptureDevice.DeviceType + Position so the app can
/// enumerate, cycle, and persist a specific camera choice.
struct CameraDevice: Hashable, Identifiable {

    /// Unique identifier derived from device type + position.
    var id: String { "\(position.rawValue)-\(deviceTypeRawValue)" }

    /// The AVFoundation device type (e.g., `.builtInWideAngleCamera`).
    let deviceType: AVCaptureDevice.DeviceType

    /// Front or back.
    let position: AVCaptureDevice.Position

    /// User-facing name (e.g., "Wide", "Ultra Wide", "Front").
    let localizedName: String

    /// Raw string for the device type — used for persistence and ID.
    /// `AVCaptureDevice.DeviceType` isn't directly Codable, so we store
    /// its rawValue string.
    var deviceTypeRawValue: String { deviceType.rawValue }

    // MARK: - Factory

    /// Build a `CameraDevice` from a real `AVCaptureDevice`.
    static func from(_ device: AVCaptureDevice) -> CameraDevice {
        CameraDevice(
            deviceType: device.deviceType,
            position: device.position,
            localizedName: displayName(for: device.deviceType, position: device.position)
        )
    }

    /// Resolve the underlying `AVCaptureDevice` from AVFoundation.
    /// Returns `nil` if the hardware is no longer available.
    func avCaptureDevice() -> AVCaptureDevice? {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [deviceType],
            mediaType: .video,
            position: position
        )
        return session.devices.first
    }

    // MARK: - Display Names

    private static func displayName(
        for type: AVCaptureDevice.DeviceType,
        position: AVCaptureDevice.Position
    ) -> String {
        if position == .front {
            return "Front"
        }
        switch type {
        case .builtInWideAngleCamera:
            return "Wide"
        case .builtInUltraWideCamera:
            return "Ultra Wide"
        case .builtInTelephotoCamera:
            return "Telephoto"
        default:
            return "Camera"
        }
    }
}

// MARK: - Persistence Helpers

extension CameraDevice {
    /// A compact string for UserDefaults storage (e.g., "1-builtInWideAngleCamera").
    var persistenceKey: String { id }

    /// Sensible fallback when no persisted/available camera is found.
    static let defaultBackWide = CameraDevice(
        deviceType: .builtInWideAngleCamera,
        position: .back,
        localizedName: "Wide"
    )

    /// Reconstruct from a persistence key. Returns `nil` if the format is invalid
    /// or the device type is unrecognized.
    static func from(persistenceKey: String) -> CameraDevice? {
        let parts = persistenceKey.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let positionRaw = Int(parts[0]),
              let position = AVCaptureDevice.Position(rawValue: positionRaw) else {
            return nil
        }
        let typeRaw = String(parts[1])
        let deviceType = AVCaptureDevice.DeviceType(rawValue: typeRaw)

        // Validate the device type is one we support
        let supportedTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        guard supportedTypes.contains(deviceType) else { return nil }

        return CameraDevice(
            deviceType: deviceType,
            position: position,
            localizedName: displayName(for: deviceType, position: position)
        )
    }
}
