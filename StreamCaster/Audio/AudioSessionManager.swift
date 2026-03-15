// AudioSessionManager.swift
// StreamCaster
//
// ──────────────────────────────────────────────────────────────────
// AudioSessionManager handles all audio-related functionality:
//   - Configuring the audio session for live streaming
//   - Muting and unmuting the microphone
//   - Detecting audio interruptions (incoming calls, Siri, etc.)
//   - Monitoring audio route changes (headphones connected/disconnected)
//
// It wraps Apple's AVAudioSession APIs in a clean interface so the
// rest of the app doesn't need to deal with low-level audio setup.
// ──────────────────────────────────────────────────────────────────

import AVFoundation
import Combine

final class AudioSessionManager: AudioSessionManagerProtocol {

    // MARK: - Mute State

    /// `true` when the microphone is muted. Views and other services
    /// can observe changes via `isMutedPublisher`.
    @Published private(set) var isMuted: Bool = false

    /// A Combine publisher that emits whenever `isMuted` changes.
    /// ViewModels subscribe to this to update the UI (e.g., show a
    /// mute icon on the stream controls).
    var isMutedPublisher: AnyPublisher<Bool, Never> {
        $isMuted.eraseToAnyPublisher()
    }

    // MARK: - Private Properties

    /// Shortcut to the shared AVAudioSession instance.
    /// There's only one audio session per app — we just reference it here.
    private let audioSession = AVAudioSession.sharedInstance()

    // MARK: - Configure

    /// Set up the audio session for live streaming.
    ///
    /// This configures the session with:
    ///   - Category `.playAndRecord` — we need both microphone input
    ///     (to capture the streamer's voice) and speaker output
    ///     (to play monitoring audio or alerts).
    ///   - Mode `.default` — standard audio processing, suitable for
    ///     most streaming scenarios.
    ///   - Options:
    ///     - `.allowBluetooth` — lets AirPods and other Bluetooth
    ///       headsets work as microphone input.
    ///     - `.defaultToSpeaker` — audio plays through the speaker
    ///       (not the earpiece) when no headphones are connected.
    ///
    /// - Throws: If iOS refuses the audio session configuration.
    func configureForStreaming() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .defaultToSpeaker]
        )

        // Activate the session so we actually start using the microphone.
        try audioSession.setActive(true, options: [])
    }

    // MARK: - Mute / Unmute

    /// Mute the microphone.
    ///
    /// The RTMP connection stays alive — we just stop sending real
    /// audio data and send silence instead. This way, the stream
    /// doesn't disconnect when the user mutes.
    func mute() {
        isMuted = true
    }

    /// Unmute the microphone so audio is captured and sent again.
    func unmute() {
        isMuted = false
    }

    // MARK: - Deactivate

    /// Deactivate the audio session when streaming stops.
    ///
    /// This tells iOS we're done using the microphone and speaker,
    /// freeing them for other apps (Music, Phone, etc.).
    /// We use `.notifyOthersOnDeactivation` so apps like Music
    /// know they can resume playback.
    func deactivate() {
        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Deactivation can fail if another app has already grabbed
            // the audio session. This is usually harmless — log and move on.
            print("[AudioSessionManager] Failed to deactivate audio session: \(error)")
        }

        // Reset mute state so the next stream starts unmuted.
        isMuted = false
    }

    // MARK: - Interruption Publisher

    /// Returns a publisher that emits when iOS interrupts the audio session.
    ///
    /// Common interruptions:
    ///   - Incoming phone call → `began = true`
    ///   - Phone call ends → `began = false, shouldResume = true`
    ///   - Siri activation → brief interruption with `shouldResume = true`
    ///
    /// The StreamingEngine listens to this to automatically mute/unmute
    /// or pause/resume streaming as needed.
    func interruptionPublisher() -> AnyPublisher<AudioInterruptionEvent, Never> {
        // Listen for the system notification that iOS posts when
        // audio is interrupted or restored.
        NotificationCenter.default.publisher(
            for: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        .compactMap { notification -> AudioInterruptionEvent? in
            // The notification's userInfo dictionary contains the details.
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return nil
            }

            switch type {
            case .began:
                // Interruption started — another app took the audio session.
                return AudioInterruptionEvent(began: true, shouldResume: false)

            case .ended:
                // Interruption ended — check if we should automatically resume.
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                let shouldResume = options.contains(.shouldResume)
                return AudioInterruptionEvent(began: false, shouldResume: shouldResume)

            @unknown default:
                return nil
            }
        }
        .eraseToAnyPublisher()
    }

    // MARK: - Route Change Publisher

    /// Returns a publisher that emits when the audio output route changes.
    ///
    /// Examples of route changes:
    ///   - User plugs in headphones → "NewDeviceAvailable"
    ///   - User unplugs headphones → "OldDeviceUnavailable"
    ///   - Bluetooth speaker connects → "NewDeviceAvailable"
    ///
    /// The StreamingEngine can use this to, for example, warn the user
    /// that audio is now playing through the speaker (no longer private).
    func routeChangePublisher() -> AnyPublisher<AudioRouteChangeEvent, Never> {
        // Listen for the system notification about audio route changes.
        NotificationCenter.default.publisher(
            for: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
        .compactMap { notification -> AudioRouteChangeEvent? in
            // Extract the reason for the route change from userInfo.
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return nil
            }

            // Convert the reason enum to a human-readable string.
            let reasonString: String
            switch reason {
            case .newDeviceAvailable:
                reasonString = "NewDeviceAvailable"
            case .oldDeviceUnavailable:
                reasonString = "OldDeviceUnavailable"
            case .categoryChange:
                reasonString = "CategoryChange"
            case .override:
                reasonString = "Override"
            case .wakeFromSleep:
                reasonString = "WakeFromSleep"
            case .noSuitableRouteForCategory:
                reasonString = "NoSuitableRouteForCategory"
            case .routeConfigurationChange:
                reasonString = "RouteConfigurationChange"
            @unknown default:
                reasonString = "Unknown"
            }

            return AudioRouteChangeEvent(reason: reasonString)
        }
        .eraseToAnyPublisher()
    }
}
