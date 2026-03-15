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
//
// PRIVACY-FIRST RULE: After an audio interruption ends, the microphone
// stays MUTED until the user explicitly taps the unmute button.
// This prevents accidentally broadcasting a private phone conversation.
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

    /// Keeps our NotificationCenter subscriptions alive. When this set
    /// is deallocated, all subscriptions are automatically cancelled.
    private var cancellables = Set<AnyCancellable>()

    /// Subject that re-emits interruption events so external subscribers
    /// (like StreamingEngine) can react. We process the notification
    /// internally first (mute the mic, reactivate the session), then
    /// forward the event through this subject.
    private let interruptionSubject = PassthroughSubject<AudioInterruptionEvent, Never>()

    /// Subject that re-emits route change events for external subscribers.
    private let routeChangeSubject = PassthroughSubject<AudioRouteChangeEvent, Never>()

    // MARK: - Init

    init() {
        // Start listening for audio interruptions and route changes
        // immediately so we never miss an event.
        observeInterruptions()
        observeRouteChanges()
    }

    // MARK: - Configure

    /// Set up the audio session for live streaming.
    ///
    /// This configures the session with:
    ///   - Category `.playAndRecord` — we need both microphone input
    ///     (to capture the streamer's voice) and speaker output
    ///     (to play monitoring audio or alerts).
    ///   - Mode `.videoChat` — optimized audio processing for
    ///     live video streaming scenarios.
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
            mode: .videoChat,
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
    /// The user must call this explicitly — we NEVER auto-unmute
    /// after an interruption (privacy-first design).
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
    /// IMPORTANT: This manager already handles the interruption internally
    /// (muting on began, reactivating on ended). The publisher lets the
    /// StreamingEngine know what happened so it can take additional action
    /// — for example, stopping the stream if we're in audio-only mode.
    func interruptionPublisher() -> AnyPublisher<AudioInterruptionEvent, Never> {
        interruptionSubject.eraseToAnyPublisher()
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
        routeChangeSubject.eraseToAnyPublisher()
    }

    // MARK: - Internal Notification Observers

    /// Subscribe to `AVAudioSession.interruptionNotification`.
    ///
    /// iOS posts this notification when something else needs the audio
    /// hardware — for example:
    ///   • An incoming phone call
    ///   • Siri is activated
    ///   • An alarm goes off
    ///
    /// We handle two cases:
    ///   1. `.began`  — interruption started → mute the mic immediately
    ///   2. `.ended`  — interruption ended   → reactivate session, but
    ///      keep the mic MUTED (privacy-first design)
    private func observeInterruptions() {
        NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification, object: audioSession)
            .sink { [weak self] notification in
                self?.handleInterruption(notification)
            }
            .store(in: &cancellables)
    }

    /// Subscribe to `AVAudioSession.routeChangeNotification`.
    ///
    /// iOS posts this when the audio route changes — for example,
    /// plugging in headphones or disconnecting Bluetooth.
    private func observeRouteChanges() {
        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification, object: audioSession)
            .sink { [weak self] notification in
                self?.handleRouteChange(notification)
            }
            .store(in: &cancellables)
    }

    // MARK: - Interruption Handling

    /// Handle audio session interruptions (incoming calls, Siri, etc.)
    ///
    /// PRIVACY-FIRST RULE: After an audio interruption ends, the microphone
    /// stays MUTED until the user explicitly taps the unmute button.
    /// This prevents accidentally broadcasting a private phone conversation.
    ///
    /// Flow:
    ///   1. Interruption begins → mute mic, publish `.began` event
    ///   2. Interruption ends   → reactivate session, keep muted,
    ///      publish `.ended` event with `shouldResume` flag
    ///
    /// The StreamingEngine subscribes to the published events and decides:
    ///   - Audio-only stream + interruption → stop the stream (.errorAudio)
    ///   - Video+audio stream + interruption → mute audio, keep video going
    private func handleInterruption(_ notification: Notification) {
        // Extract the interruption type from the notification's userInfo.
        // AVAudioSession packs this as a UInt inside the dictionary.
        guard
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            // ── Interruption STARTED ──
            // Another app (Phone, Siri, alarm) has taken the microphone.
            // Mute immediately so we don't accidentally broadcast silence
            // or garbage audio to viewers.
            mute()
            print("[AudioSessionManager] Audio interrupted — mic muted")

            // Tell subscribers (StreamingEngine) that an interruption began.
            // The engine will decide whether to stop the stream (audio-only)
            // or just keep streaming video with muted audio.
            let event = AudioInterruptionEvent(began: true, shouldResume: false)
            interruptionSubject.send(event)

        case .ended:
            // ── Interruption ENDED ──
            // The phone call or Siri activation is over. iOS is giving us
            // the microphone back.

            // Check if iOS thinks we should automatically resume audio.
            let shouldResume: Bool
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            } else {
                shouldResume = false
            }

            // Reactivate the audio session so we CAN capture audio again.
            // Even if shouldResume is false, we try to reactivate because
            // the user might want to unmute manually later.
            do {
                try audioSession.setActive(true, options: [])
                print("[AudioSessionManager] Audio session reactivated after interruption")
            } catch {
                print("[AudioSessionManager] Failed to reactivate after interruption: \(error)")
            }

            // IMPORTANT: Keep the mic MUTED even though iOS says we can resume.
            // The user must explicitly tap "unmute" to start broadcasting audio.
            // This is our privacy-first design — after a phone call, we don't
            // want to accidentally broadcast the user's private conversation.
            //
            // (isMuted stays true — it was set to true in the .began handler)

            print("[AudioSessionManager] Interruption ended — mic stays muted (privacy-first)")

            // Tell subscribers the interruption is over.
            let event = AudioInterruptionEvent(began: false, shouldResume: shouldResume)
            interruptionSubject.send(event)

        @unknown default:
            // Future-proof: if Apple adds a new interruption type,
            // we log it but don't crash.
            print("[AudioSessionManager] Unknown interruption type: \(typeValue)")
        }
    }

    // MARK: - Route Change Handling

    /// Handle audio route changes (headphones plugged in, Bluetooth, etc.).
    ///
    /// We convert the raw notification into a simple `AudioRouteChangeEvent`
    /// and publish it so other parts of the app can react (e.g., update UI).
    private func handleRouteChange(_ notification: Notification) {
        // Extract the reason for the route change from userInfo.
        guard
            let userInfo = notification.userInfo,
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return
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
        case .unknown:
            reasonString = "Unknown"
        @unknown default:
            reasonString = "Unknown(\(reasonValue))"
        }

        let event = AudioRouteChangeEvent(reason: reasonString)
        routeChangeSubject.send(event)
    }
}
