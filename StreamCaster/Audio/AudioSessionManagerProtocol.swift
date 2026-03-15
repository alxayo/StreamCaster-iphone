import Foundation
import Combine

// MARK: - AudioInterruptionEvent
/// Describes an audio session interruption — for example, an incoming phone
/// call that steals the microphone.
struct AudioInterruptionEvent: Equatable {
    /// `true` when the interruption starts (audio is taken away),
    /// `false` when it ends (audio is given back).
    let began: Bool

    /// `true` if the audio session should automatically resume when the
    /// interruption ends (e.g., a short Siri activation).
    let shouldResume: Bool
}

// MARK: - AudioRouteChangeEvent
/// Describes a change in the audio route — for example, plugging in headphones
/// or connecting a Bluetooth speaker.
struct AudioRouteChangeEvent: Equatable {
    /// A human-readable description of the reason for the route change
    /// (e.g., "NewDeviceAvailable", "OldDeviceUnavailable").
    let reason: String
}

// MARK: - AudioSessionManagerProtocol
/// Manages the iOS audio session — configuring it for live streaming,
/// handling interruptions (phone calls, Siri), and reporting route changes
/// (headphones plugged in, Bluetooth connected).
///
/// The real implementation wraps `AVAudioSession.sharedInstance()`.
protocol AudioSessionManagerProtocol {

    /// `true` when the microphone is currently muted.
    var isMuted: Bool { get }

    /// A publisher that emits `true`/`false` whenever the mute state changes.
    var isMutedPublisher: AnyPublisher<Bool, Never> { get }

    /// Set up the audio session for live streaming: category `.playAndRecord`,
    /// mode `.videoChat`, and the appropriate options for mixing and Bluetooth.
    /// - Throws: If `AVAudioSession` configuration fails.
    func configureForStreaming() throws

    /// Mute the microphone. Silent audio frames are still sent to keep the
    /// RTMP connection alive.
    func mute()

    /// Unmute the microphone so the viewer can hear audio again.
    func unmute()

    /// Deactivate the audio session when streaming stops, freeing the
    /// microphone for other apps.
    func deactivate()

    /// A publisher that emits events when iOS interrupts or restores the
    /// audio session (e.g., phone call starts/ends).
    func interruptionPublisher() -> AnyPublisher<AudioInterruptionEvent, Never>

    /// A publisher that emits events when the audio output route changes
    /// (e.g., headphones connected/disconnected).
    func routeChangePublisher() -> AnyPublisher<AudioRouteChangeEvent, Never>
}
