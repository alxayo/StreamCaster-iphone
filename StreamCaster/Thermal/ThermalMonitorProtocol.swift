import Foundation
import Combine

// MARK: - ThermalMonitorProtocol
/// Observes the device's thermal state (how hot the phone is getting).
/// The streaming engine uses this to decide when to reduce quality
/// (lower bitrate, drop frame rate) and when to warn the user.
///
/// On a real device, the implementation wraps `ProcessInfo.thermalState`.
/// In tests, a mock can simulate overheating without melting your Mac.
protocol ThermalMonitorProtocol {

    /// The thermal level right now. Read this for one-off checks.
    var currentLevel: ThermalLevel { get }

    /// A Combine publisher that emits a new `ThermalLevel` every time the
    /// device's thermal state changes. Subscribe to this for continuous
    /// monitoring.
    var thermalLevelPublisher: AnyPublisher<ThermalLevel, Never> { get }
}
