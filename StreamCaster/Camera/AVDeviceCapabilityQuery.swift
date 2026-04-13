// AVDeviceCapabilityQuery.swift
// StreamCaster
//
// Queries AVFoundation for real camera capabilities (resolutions,
// frame rates, available cameras) without ever opening or activating
// a capture session. Results are cached because device hardware
// doesn't change while the app is running.

import AVFoundation
import Foundation

// MARK: - Device Tier

/// Classifies the device by how much RAM it has. More RAM generally
/// means the device can handle higher-quality encoding settings.
///
///  - Tier 1: Less than 3 GB RAM (older iPhones like 7/8/X)
///  - Tier 2: 3–4 GB RAM (mid-range, e.g. iPhone 11/12)
///  - Tier 3: More than 4 GB RAM (flagship, e.g. iPhone 14 Pro+)
enum DeviceTier: Int, Comparable {
    case tier1 = 1
    case tier2 = 2
    case tier3 = 3

    static func < (lhs: DeviceTier, rhs: DeviceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AVDeviceCapabilityQuery

/// Concrete implementation of `DeviceCapabilityQuery` that talks to
/// real AVFoundation APIs. It is completely read-only — it never
/// opens a camera or starts a capture session.
final class AVDeviceCapabilityQuery: DeviceCapabilityQuery {

    // ──────────────────────────────────────────────────────────
    // MARK: - Constants
    // ──────────────────────────────────────────────────────────

    /// The streaming resolutions we care about. Any resolution the
    /// camera supports that isn't in this list gets ignored because
    /// it's not useful for standard live-streaming.
    private static let streamingResolutions: [Resolution] = [
        Resolution(width: 854, height: 480),   // 480p  (SD)
        Resolution(width: 960, height: 540),   // 540p  (qHD)
        Resolution(width: 1280, height: 720),  // 720p  (HD)
        Resolution(width: 1920, height: 1080)  // 1080p (Full HD)
    ]

    // ──────────────────────────────────────────────────────────
    // MARK: - Cache
    // ──────────────────────────────────────────────────────────

    /// Once we've queried a camera's resolutions, we store them here
    /// so we don't have to query AVFoundation again.
    /// Key = camera position (front / back), Value = sorted resolutions.
    private var cachedResolutions: [AVCaptureDevice.Position: [Resolution]] = [:]

    /// Cached frame rates for each (resolution + camera) combination.
    /// Key = a string like "1280x720-back", Value = array of FPS ints.
    private var cachedFrameRates: [String: [Int]] = [:]

    /// Cached list of all camera devices (including ultra-wide, telephoto).
    private var cachedCameraDevices: [CameraDevice]?

    /// Cached result of the Tier 1 device check.
    private var cachedIsTier1: Bool?

    // ──────────────────────────────────────────────────────────
    // MARK: - DeviceCapabilityQuery Protocol
    // ──────────────────────────────────────────────────────────

    /// Returns which cameras (front, back, etc.) exist on this device.
    func availableCameras() -> [AVCaptureDevice.Position] {
        // Derive from the richer camera device list
        let devices = availableCameraDevices()
        let positions = Array(Set(devices.map { $0.position }))
            .sorted { $0.rawValue < $1.rawValue }
        return positions
    }

    /// Returns all individual camera devices on this device, including
    /// ultra-wide and telephoto lenses on supported hardware.
    func availableCameraDevices() -> [CameraDevice] {
        if let cached = cachedCameraDevices {
            return cached
        }

        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        let devices = discoverySession.devices.map { CameraDevice.from($0) }
        cachedCameraDevices = devices
        return devices
    }

    /// Returns the stabilization modes supported by the given camera device.
    func supportedStabilizationModes(for camera: CameraDevice) -> [AVCaptureVideoStabilizationMode] {
        guard let avDevice = camera.avCaptureDevice() else { return [] }

        let allModes: [AVCaptureVideoStabilizationMode] = [
            .standard,
            .cinematic,
            .cinematicExtended
        ]

        // Check the active format's supported modes.
        // If no active format yet, check the first available format.
        let format = avDevice.activeFormat
        return allModes.filter { format.isVideoStabilizationModeSupported($0) }
    }

    /// Returns the standard streaming resolutions that a camera actually supports.
    /// For example, a front camera might support 480p and 720p but not 1080p.
    func supportedResolutions(for camera: AVCaptureDevice.Position) -> [Resolution] {
        // Return cached result if available
        if let cached = cachedResolutions[camera] {
            return cached
        }

        // Find the AVCaptureDevice for the requested camera position
        guard let device = findDevice(for: camera) else {
            // No camera found at this position — return empty array
            return []
        }

        // Collect all resolutions that the camera's formats support
        var deviceResolutions = Set<Resolution>()

        // Each format describes a configuration the camera can run in.
        // We check if its resolution matches one of our standard sizes.
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            let resolution = Resolution(width: width, height: height)

            // Only keep resolutions that match our streaming presets
            if Self.streamingResolutions.contains(resolution) {
                deviceResolutions.insert(resolution)
            }
        }

        // Sort from smallest to largest by total pixel count
        let sorted = deviceResolutions.sorted {
            ($0.width * $0.height) < ($1.width * $1.height)
        }

        cachedResolutions[camera] = sorted
        return sorted
    }

    /// Returns the frame rates available at a specific resolution on a given camera.
    /// On Tier 1 devices (A10/A11), 60 fps is filtered out because those chips
    /// can't sustain 60 fps encoding without thermal throttling.
    func supportedFrameRates(
        for resolution: Resolution,
        camera: AVCaptureDevice.Position
    ) -> [Int] {
        // Build a cache key like "1280x720-1" (resolution + position rawValue)
        let cacheKey = "\(resolution.width)x\(resolution.height)-\(camera.rawValue)"

        if let cached = cachedFrameRates[cacheKey] {
            return cached
        }

        guard let device = findDevice(for: camera) else {
            return []
        }

        // The standard frame rates we care about for streaming
        let targetFrameRates = [24, 30, 60]

        // Collect the maximum supported frame rate across all formats
        // that match the requested resolution
        var supportedFPS = Set<Int>()

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)

            // Skip formats that don't match the requested resolution
            guard width == resolution.width && height == resolution.height else {
                continue
            }

            // Each format has one or more frame rate ranges.
            // Check which of our target frame rates fall within a range.
            for range in format.videoSupportedFrameRateRanges {
                let minFPS = Int(range.minFrameRate)
                let maxFPS = Int(range.maxFrameRate)

                for fps in targetFrameRates {
                    if fps >= minFPS && fps <= maxFPS {
                        supportedFPS.insert(fps)
                    }
                }
            }
        }

        // On Tier 1 devices (A10/A11), remove 60 fps — those chips
        // overheat when encoding at 60 fps for extended periods.
        if isTier1Device() {
            supportedFPS.remove(60)
        }

        let sorted = supportedFPS.sorted()

        cachedFrameRates[cacheKey] = sorted
        return sorted
    }

    /// Returns `true` if this device has an A10 or A11 chip.
    /// These older processors can't sustain 60 fps encoding without
    /// overheating, so we limit them to 30 fps max.
    ///
    /// Device identifiers:
    ///  - iPhone9,x  → iPhone 7 / 7 Plus (A10 Fusion)
    ///  - iPhone10,x → iPhone 8 / 8 Plus / X (A11 Bionic)
    func isTier1Device() -> Bool {
        // Return cached result — the chip doesn't change at runtime!
        if let cached = cachedIsTier1 {
            return cached
        }

        // Read the hardware model string (e.g. "iPhone10,3")
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        // iPhone9,x = iPhone 7 family (A10)
        // iPhone10,x = iPhone 8/X family (A11)
        let result = machine.hasPrefix("iPhone9,") || machine.hasPrefix("iPhone10,")

        cachedIsTier1 = result
        return result
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Device Tier (Extra Property)
    // ──────────────────────────────────────────────────────────

    /// Classifies this device into a performance tier based on how
    /// much physical RAM it has. This helps the app choose sensible
    /// default settings.
    ///
    ///  - Tier 1: < 3 GB — stick to 720p30 or lower
    ///  - Tier 2: 3–4 GB — comfortable at 1080p30
    ///  - Tier 3: > 4 GB — can handle 1080p60 + recording
    var deviceTier: DeviceTier {
        // physicalMemory returns bytes; convert to gigabytes
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(ramBytes) / (1024 * 1024 * 1024)

        if ramGB < 3.0 {
            return .tier1
        } else if ramGB <= 4.0 {
            return .tier2
        } else {
            return .tier3
        }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Private Helpers
    // ──────────────────────────────────────────────────────────

    /// Finds the AVCaptureDevice for a given camera position.
    /// Uses DiscoverySession so we never have to activate the camera.
    private func findDevice(
        for position: AVCaptureDevice.Position
    ) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        // Return the first device found at the requested position
        return discoverySession.devices.first
    }
}
