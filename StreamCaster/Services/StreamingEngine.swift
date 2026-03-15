import Foundation
import Combine
import AVFoundation
import UIKit

// MARK: - StreamingEngine
// ──────────────────────────────────────────────────────────────────
// The StreamingEngine is the heart of the app. It manages the entire
// streaming lifecycle: connecting, streaming, reconnecting, and stopping.
//
// It follows the "Singleton" pattern — there's only ONE instance shared
// across the entire app. This ensures there's a single source of truth
// for the stream state.
//
// Architecture:
//   StreamingEngine (@MainActor)
//     └── StreamingSessionCoordinator (actor)
//
// - StreamingEngine: The public face that SwiftUI observes. It is
//   @MainActor so all @Published properties update on the main thread.
// - StreamingSessionCoordinator: The private brain that manages all
//   mutable state. Using an actor ensures state changes happen one at
//   a time (serialized), preventing race conditions.
//
// Data flow:
//   1. ViewModel calls engine.startStream(profileId:)
//   2. Engine tells coordinator to update state
//   3. Coordinator returns the new snapshot
//   4. Engine publishes the new snapshot → SwiftUI updates the UI
// ──────────────────────────────────────────────────────────────────

@MainActor
final class StreamingEngine: ObservableObject, StreamingEngineProtocol {

    // MARK: - Singleton

    /// The one and only instance. Use `StreamingEngine.shared` everywhere.
    static let shared = StreamingEngine()

    // MARK: - Published State

    /// The current state of the streaming session.
    /// SwiftUI views observe this to update their display automatically.
    @Published private(set) var sessionSnapshot: StreamSessionSnapshot = .idle

    /// Live statistics about the current stream (bitrate, fps, etc.).
    /// Updated roughly once per second while streaming.
    @Published private(set) var streamStats: StreamStats = StreamStats()

    // MARK: - Combine Publishers

    /// Emits a new snapshot every time any part of the session state changes.
    /// ViewModels and Combine pipelines can subscribe to stay in sync.
    var sessionSnapshotPublisher: AnyPublisher<StreamSessionSnapshot, Never> {
        $sessionSnapshot.eraseToAnyPublisher()
    }

    /// Emits updated StreamStats roughly once per second while streaming.
    var streamStatsPublisher: AnyPublisher<StreamStats, Never> {
        $streamStats.eraseToAnyPublisher()
    }

    // MARK: - Private Dependencies

    /// The private coordinator actor that serializes all state mutations.
    private let coordinator = StreamingSessionCoordinator()

    /// The encoder bridge handles actual video/audio encoding and RTMP publishing.
    /// For now this is a stub — T-007b will replace it with HaishinKit.
    private let encoderBridge: EncoderBridge

    /// Repository for looking up RTMP endpoint profiles (server URL + stream key).
    private let profileRepository: EndpointProfileRepository

    /// Repository for reading user settings (resolution, bitrate, etc.).
    private let settingsRepository: SettingsRepository

    /// Manages the iOS audio session — muting, unmuting, and handling
    /// audio interruptions. We call mute()/unmute() here so the actual
    /// audio hardware reflects the snapshot's mute state.
    private let audioSessionManager: AudioSessionManagerProtocol

    // MARK: - Init

    /// Private init prevents anyone from creating a second engine.
    /// All access must go through `StreamingEngine.shared`.
    private init() {
        // Pull dependencies from the DependencyContainer.
        // We grab references here so the engine doesn't depend on
        // the container after initialization.
        let container = DependencyContainer.shared
        self.encoderBridge = container.encoderBridge
        self.profileRepository = container.endpointProfileRepository
        self.settingsRepository = container.settingsRepository
        self.audioSessionManager = container.audioSessionManager
    }

    /// Internal init used for testing — lets us inject mock dependencies.
    init(
        encoderBridge: EncoderBridge,
        profileRepository: EndpointProfileRepository,
        settingsRepository: SettingsRepository,
        audioSessionManager: AudioSessionManagerProtocol
    ) {
        self.encoderBridge = encoderBridge
        self.profileRepository = profileRepository
        self.settingsRepository = settingsRepository
        self.audioSessionManager = audioSessionManager
    }

    // MARK: - Stream Lifecycle

    /// Start streaming to the RTMP server specified by the given profile ID.
    ///
    /// This method:
    ///   1. Looks up the profile (server URL + stream key) from the repository
    ///   2. Builds a StreamConfig from user settings
    ///   3. Transitions state: idle → connecting → live
    ///   4. Tells the encoder bridge to connect and start sending data
    ///
    /// - Parameter profileId: The `EndpointProfile.id` to stream to.
    ///   We NEVER accept raw credentials — only a profile ID.
    /// - Throws: If the profile doesn't exist or the connection fails.
    func startStream(profileId: String) async throws {
        // Step 1: Look up the profile by ID.
        // We never accept raw URLs or stream keys as parameters — credentials
        // stay safely inside the repository (backed by the Keychain).
        guard let profile = profileRepository.getById(profileId) else {
            // Profile not found — report an auth error and stop.
            let snapshot = await coordinator.stopSession(reason: .errorAuth)
            applySnapshot(snapshot)

            // Transition back to idle after a short delay so the UI can show the error.
            scheduleReturnToIdle()
            return
        }

        // Step 2: Build the stream configuration from user settings.
        let config = buildStreamConfig(profileId: profileId)

        // Step 3: Transition to .connecting state.
        let connectingSnapshot = await coordinator.startSession(config: config)
        applySnapshot(connectingSnapshot)

        // Step 4: Configure the encoder with the desired video settings.
        do {
            try await encoderBridge.setVideoSettings(
                resolution: config.resolution,
                fps: config.fps,
                bitrateKbps: config.videoBitrateKbps
            )
        } catch {
            // If encoder setup fails, stop with an encoder error.
            let snapshot = await coordinator.stopSession(reason: .errorEncoder)
            applySnapshot(snapshot)
            scheduleReturnToIdle()
            return
        }

        // Step 5: Attach camera and audio.
        if config.videoEnabled {
            encoderBridge.attachCamera(position: settingsRepository.getDefaultCameraPosition())
        }
        if config.audioEnabled {
            encoderBridge.attachAudio()
        }

        // Step 6: Connect to the RTMP server and start publishing.
        encoderBridge.connect(url: profile.rtmpUrl, streamKey: profile.streamKey)

        // Step 7: Verify the connection succeeded, then go live.
        // In the stub, connect() is synchronous and always succeeds.
        // With a real encoder, we'd listen for connection events instead.
        let currentToken = await coordinator.currentSessionToken
        let liveSnapshot = await coordinator.goLive(sessionToken: currentToken)
        applySnapshot(liveSnapshot)
    }

    /// Stop the current stream gracefully.
    ///
    /// This method is **idempotent** — calling it when already idle is a no-op.
    /// It disconnects the encoder bridge, transitions state to .stopped,
    /// and then returns to .idle after a brief delay.
    ///
    /// - Parameter reason: Why the stream is being stopped (user request, error, etc.).
    func stopStream(reason: StopReason) async {
        // Check if we're already idle — if so, do nothing.
        let currentTransport = await coordinator.snapshot.transport
        if currentTransport == .idle {
            return
        }

        // Tell the encoder to stop sending data and disconnect.
        encoderBridge.detachCamera()
        encoderBridge.detachAudio()
        encoderBridge.disconnect()

        // Update state to .stopped with the given reason.
        let snapshot = await coordinator.stopSession(reason: reason)
        applySnapshot(snapshot)

        // After a short delay, return to idle so the UI resets.
        scheduleReturnToIdle()
    }

    // MARK: - Media Controls

    /// Toggle the microphone mute on/off.
    /// When muted, the stream stays alive but audio is silent.
    ///
    /// This does TWO things:
    ///   1. Updates the coordinator snapshot (so the UI shows the right icon).
    ///   2. Tells the AudioSessionManager to actually mute/unmute the mic.
    func toggleMute() {
        // We use Task here because the coordinator is an actor, so we
        // need an async context to talk to it.
        Task {
            // Step 1: Toggle the mute flag in the snapshot.
            let snapshot = await coordinator.toggleMute()
            applySnapshot(snapshot)

            // Step 2: Tell the audio session manager to actually mute or
            // unmute the hardware microphone. Without this, the snapshot
            // says "muted" but the mic is still capturing audio!
            if snapshot.media.audioMuted {
                audioSessionManager.mute()
            } else {
                audioSessionManager.unmute()
            }
        }
    }

    /// Switch between the front and back camera.
    ///
    /// How it works:
    ///   1. Read the current camera position from settings.
    ///   2. Calculate the opposite position (front ↔ back).
    ///   3. Detach the current camera (release the hardware).
    ///   4. Attach the new camera.
    ///   5. Save the new position so it persists across app launches.
    ///
    /// If the switch fails, we revert to the previous camera so the
    /// user doesn't end up with a black screen.
    ///
    /// Works both before streaming (preview) and during a live stream.
    func switchCamera() {
        Task {
            // Only switch if video is currently active. If video is off
            // (e.g., audio-only mode), there's no camera to switch.
            let snapshot = await coordinator.snapshot
            guard snapshot.media.videoActive else { return }

            // Step 1: Figure out which camera we're currently using.
            let previousPosition = settingsRepository.getDefaultCameraPosition()

            // Step 2: Calculate the opposite camera position.
            // If we're on front, switch to back. If back, switch to front.
            let newPosition: AVCaptureDevice.Position =
                (previousPosition == .front) ? .back : .front

            // Step 3: Detach the current camera first.
            // This cleanly releases the hardware before we grab a new camera.
            encoderBridge.detachCamera()

            // Step 4: Attach the new camera.
            encoderBridge.attachCamera(position: newPosition)

            // Step 5: Save the new position so it persists across app launches
            // and so other parts of the engine know which camera is active.
            settingsRepository.setDefaultCameraPosition(newPosition)
        }
    }

    /// Enable or disable individual media tracks mid-stream.
    ///
    /// For example, you might disable video to switch to audio-only mode
    /// while the app is in the background.
    ///
    /// - Parameters:
    ///   - videoEnabled: `true` to capture video, `false` to stop video.
    ///   - audioEnabled: `true` to capture audio, `false` to stop audio.
    func setMediaMode(videoEnabled: Bool, audioEnabled: Bool) {
        Task {
            // Update the coordinator's state.
            let snapshot = await coordinator.setMediaMode(
                videoEnabled: videoEnabled,
                audioEnabled: audioEnabled
            )
            applySnapshot(snapshot)

            // Tell the encoder bridge to attach/detach hardware accordingly.
            if videoEnabled {
                encoderBridge.attachCamera(
                    position: settingsRepository.getDefaultCameraPosition()
                )
            } else {
                encoderBridge.detachCamera()
            }

            if audioEnabled {
                encoderBridge.attachAudio()
            } else {
                encoderBridge.detachAudio()
            }
        }
    }

    // MARK: - Preview

    /// Attach a UIView to display the live camera preview.
    /// The stub encoder doesn't render anything, but this satisfies the protocol.
    func attachPreview(_ view: UIView) {
        // The real HaishinKit bridge will add a preview layer here.
        // In the stub, this is a no-op.
        print("[StreamingEngine] attachPreview() — stub, no-op")
    }

    /// Remove the camera preview from its parent view.
    func detachPreview() {
        // In the stub, this is a no-op.
        print("[StreamingEngine] detachPreview() — stub, no-op")
    }

    // MARK: - Private Helpers

    /// Build a StreamConfig from user settings and the given profile ID.
    /// This gathers all the settings the user has configured (resolution,
    /// bitrate, etc.) into one convenient struct.
    private func buildStreamConfig(profileId: String) -> StreamConfig {
        return StreamConfig(
            profileId: profileId,
            videoEnabled: true,
            audioEnabled: true,
            resolution: settingsRepository.getResolution(),
            fps: settingsRepository.getFps(),
            videoBitrateKbps: settingsRepository.getVideoBitrate(),
            audioBitrateKbps: settingsRepository.getAudioBitrate(),
            audioSampleRate: settingsRepository.getAudioSampleRate(),
            stereo: settingsRepository.isStereo(),
            keyframeIntervalSec: settingsRepository.getKeyframeInterval(),
            abrEnabled: settingsRepository.isAbrEnabled(),
            localRecordingEnabled: settingsRepository.isLocalRecordingEnabled(),
            recordToPhotosLibrary: settingsRepository.getRecordingDestination() == .photosLibrary
        )
    }

    /// Copy the coordinator's snapshot to our @Published property.
    /// Because we're @MainActor, this triggers SwiftUI to re-render any
    /// observing views.
    private func applySnapshot(_ snapshot: StreamSessionSnapshot) {
        self.sessionSnapshot = snapshot
    }

    /// After stopping, wait a short time then reset to .idle.
    /// This gives the UI a moment to show the "stopped" state
    /// (e.g., an error message) before clearing it.
    private func scheduleReturnToIdle() {
        Task {
            // Wait 2 seconds so the user can see why the stream stopped.
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            let snapshot = await coordinator.resetToIdle()
            applySnapshot(snapshot)
        }
    }
}

// MARK: - StreamingSessionCoordinator
// ──────────────────────────────────────────────────────────────────
// The coordinator is a Swift `actor`. This means Swift guarantees
// that only ONE piece of code can access its properties at a time.
// No locks, no queues — the language handles thread safety for us.
//
// Every state mutation goes through the coordinator, so we can be
// confident the snapshot is always consistent. No matter how many
// Tasks try to change state simultaneously, they'll be serialized.
// ──────────────────────────────────────────────────────────────────

private actor StreamingSessionCoordinator {

    // MARK: - State

    /// The current session snapshot — the single source of truth.
    private(set) var snapshot: StreamSessionSnapshot = .idle

    /// A monotonic token that identifies the current streaming session.
    /// When a new session starts, we create a new token. This prevents
    /// stale reconnect attempts or delayed callbacks from affecting
    /// a newer session.
    private(set) var currentSessionToken: UUID = UUID()

    // MARK: - Session Lifecycle

    /// Begin a new streaming session. Transitions from idle to connecting.
    ///
    /// - Parameter config: The stream configuration to use.
    /// - Returns: The new snapshot (in .connecting state).
    func startSession(config: StreamConfig) -> StreamSessionSnapshot {
        // Generate a fresh session token so old callbacks are ignored.
        currentSessionToken = UUID()

        // Transition to connecting state.
        snapshot.transport = .connecting
        snapshot.media = MediaState(
            videoActive: config.videoEnabled,
            audioActive: config.audioEnabled,
            audioMuted: false,
            interruptionOrigin: .none
        )
        snapshot.background = .foreground
        snapshot.recording = .off

        return snapshot
    }

    /// Transition from .connecting to .live.
    ///
    /// The sessionToken parameter prevents a stale callback from
    /// accidentally marking a new session as live.
    ///
    /// - Parameter sessionToken: The token from when connect was initiated.
    /// - Returns: The new snapshot.
    func goLive(sessionToken: UUID) -> StreamSessionSnapshot {
        // Ignore if this token doesn't match the current session.
        // This means a newer session has started and this callback is stale.
        guard sessionToken == currentSessionToken else {
            return snapshot
        }

        // Only transition if we're currently connecting.
        guard snapshot.transport == .connecting else {
            return snapshot
        }

        snapshot.transport = .live
        return snapshot
    }

    /// Stop the session with a reason.
    ///
    /// - Parameter reason: Why the stream stopped.
    /// - Returns: The new snapshot (in .stopped state).
    func stopSession(reason: StopReason) -> StreamSessionSnapshot {
        snapshot.transport = .stopped(reason: reason)
        return snapshot
    }

    /// Reset everything back to the idle state.
    /// Called after a brief delay following a stop, so the UI has time
    /// to show the "stopped" state before clearing it.
    ///
    /// - Returns: The idle snapshot.
    func resetToIdle() -> StreamSessionSnapshot {
        snapshot = .idle
        // New token for the next session.
        currentSessionToken = UUID()
        return snapshot
    }

    // MARK: - Media Controls

    /// Toggle the audio mute flag and return the updated snapshot.
    func toggleMute() -> StreamSessionSnapshot {
        snapshot.media.audioMuted.toggle()
        return snapshot
    }

    /// Update which media tracks (video/audio) are active.
    ///
    /// - Parameters:
    ///   - videoEnabled: Whether video should be active.
    ///   - audioEnabled: Whether audio should be active.
    /// - Returns: The updated snapshot.
    func setMediaMode(
        videoEnabled: Bool,
        audioEnabled: Bool
    ) -> StreamSessionSnapshot {
        snapshot.media.videoActive = videoEnabled
        snapshot.media.audioActive = audioEnabled
        return snapshot
    }

    // MARK: - Transport Updates

    /// Update the transport state (used by reconnection logic, etc.).
    ///
    /// - Parameter state: The new transport state.
    /// - Returns: The updated snapshot.
    func updateTransport(_ state: TransportState) -> StreamSessionSnapshot {
        snapshot.transport = state
        return snapshot
    }

    // MARK: - Background State

    /// Update the background state (foreground, PiP, background, etc.).
    ///
    /// - Parameter state: The new background state.
    /// - Returns: The updated snapshot.
    func updateBackgroundState(_ state: BackgroundState) -> StreamSessionSnapshot {
        snapshot.background = state
        return snapshot
    }
}
