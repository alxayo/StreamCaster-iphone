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

    /// A user-facing error message for the latest start/stream failure.
    @Published private(set) var lastErrorMessage: String?

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

    /// The encoder bridge handles actual video/audio encoding and publishing.
    ///
    /// This is `var` (not `let`) because the bridge is **recreated each time
    /// the user starts a stream**. The factory (`EncoderBridgeFactory`) picks
    /// the right bridge based on the endpoint URL:
    /// - `rtmp://` / `rtmps://` → `HaishinKitEncoderBridge`
    /// - `srt://` → `SRTEncoderBridge`
    ///
    /// A fresh bridge is created per stream so that leftover state from a
    /// previous connection (e.g., RTMP) doesn't leak into a new one (e.g., SRT).
    private var encoderBridge: EncoderBridge

    /// Holds the subscription that forwards the encoder bridge's stats
    /// to our `@Published streamStats`. Cancelled and re-created whenever
    /// the bridge is swapped (e.g., switching RTMP → SRT).
    private var statsCancellable: AnyCancellable?

    /// Weak reference to the currently attached preview view.
    /// We keep this so we can re-attach the preview when the encoder bridge
    /// is swapped (e.g., switching from RTMP to SRT triggers a new bridge).
    /// Without this, the preview would remain attached to the old bridge
    /// and the user would see a black screen.
    private weak var currentPreviewView: UIView?

    /// Repository for looking up RTMP endpoint profiles (server URL + stream key).
    private let profileRepository: EndpointProfileRepository

    /// Repository for reading user settings (resolution, bitrate, etc.).
    private let settingsRepository: SettingsRepository

    /// Manages the iOS audio session — muting, unmuting, and handling
    /// audio interruptions. We call mute()/unmute() here so the actual
    /// audio hardware reflects the snapshot's mute state.
    private let audioSessionManager: AudioSessionManagerProtocol

    /// Queries hardware for available cameras, stabilization modes, etc.
    private let capabilityQuery: DeviceCapabilityQuery

    /// All camera devices on this hardware, ordered for cycling.
    private(set) var availableCameraDevices: [CameraDevice] = []

    /// The camera currently in use (persisted across sessions).
    private(set) var currentCameraDevice: CameraDevice?

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
        self.capabilityQuery = container.deviceCapabilityQuery
        loadCameraDevices()
    }

    /// Internal init used for testing — lets us inject mock dependencies.
    init(
        encoderBridge: EncoderBridge,
        profileRepository: EndpointProfileRepository,
        settingsRepository: SettingsRepository,
        audioSessionManager: AudioSessionManagerProtocol,
        capabilityQuery: DeviceCapabilityQuery? = nil
    ) {
        self.encoderBridge = encoderBridge
        self.profileRepository = profileRepository
        self.settingsRepository = settingsRepository
        self.audioSessionManager = audioSessionManager
        self.capabilityQuery = capabilityQuery ?? AVDeviceCapabilityQuery()
        loadCameraDevices()
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
        // Clear any previous error before attempting a fresh start.
        lastErrorMessage = nil

        // Step 1: Resolve the target profile.
        // We support both explicit IDs and the legacy "default" sentinel.
        let requestedProfile = profileRepository.getById(profileId)
        let profile: EndpointProfile?
        if let requestedProfile {
            profile = requestedProfile
        } else if profileId == "default" {
            profile = profileRepository.getDefault() ?? profileRepository.getAll().first
        } else {
            profile = nil
        }

        // We never accept raw URLs or stream keys as parameters — credentials
        // stay safely inside the repository (backed by the Keychain).
        guard let profile else {
            lastErrorMessage = "No endpoint profile is configured. Open Settings > Endpoint and save one profile."

            // Profile not found — report an auth error and stop.
            let snapshot = await coordinator.stopSession(reason: .errorAuth)
            applySnapshot(snapshot)

            // Transition back to idle after a short delay so the UI can show the error.
            scheduleReturnToIdle()
            return
        }

        // Step 2: Build the stream configuration from user settings.
        // We pass the profile so the codec selection propagates into the
        // config, which the ABR system uses for codec-specific bitrate targets.
        let config = buildStreamConfig(profileId: profileId, profile: profile)

        // Step 2b: Create the correct encoder bridge for this profile's protocol.
        // The factory inspects the URL scheme (rtmp:// vs srt://) and returns
        // either an HaishinKitEncoderBridge or SRTEncoderBridge.
        // We create a NEW bridge each time so leftover state from a previous
        // stream (e.g., an RTMP connection) doesn't interfere with a new one
        // (e.g., SRT). This also means switching endpoints between RTMP and
        // SRT "just works" — no need to manually clean up the old bridge.

        // Detach preview from the old bridge before swapping.
        // The old bridge's mixer/stream still holds a reference to the
        // MTHKView, which would cause a black screen if not released.
        encoderBridge.detachPreview()
        encoderBridge.detachCamera()

        self.encoderBridge = EncoderBridgeFactory.makeBridge(for: profile)

        // Subscribe to the new bridge's stats so the HUD updates in real time.
        bindBridgeStats()

        // Re-attach the preview view to the NEW bridge so the user sees
        // the live camera feed. Without this, the preview stays wired to
        // the old (now-discarded) bridge and the screen goes black.
        if let previewView = currentPreviewView {
            encoderBridge.attachPreview(previewView)
        }

        // Step 3: Transition to .connecting state.
        let connectingSnapshot = await coordinator.startSession(config: config)
        applySnapshot(connectingSnapshot)

        // Step 4a: Configure the video codec from the endpoint profile.
        // This must happen BEFORE setVideoSettings / connect so the encoder
        // creates the correct VideoToolbox compression session (H.264 vs HEVC).
        // Awaiting ensures the codec change completes before we apply video
        // settings — without await, the two operations race and the codec
        // may still be the old one when setVideoSettings runs.
        await encoderBridge.configureCodec(profile.videoCodec)

        // Step 4b: Configure the encoder with the desired video settings.
        do {
            try await encoderBridge.setVideoSettings(
                resolution: config.resolution,
                fps: config.fps,
                bitrateKbps: config.videoBitrateKbps
            )
        } catch {
            lastErrorMessage = "Failed to configure encoder settings."

            // If encoder setup fails, stop with an encoder error.
            let snapshot = await coordinator.stopSession(reason: .errorEncoder)
            applySnapshot(snapshot)
            scheduleReturnToIdle()
            return
        }

        // Step 5: Attach camera and audio.
        if config.videoEnabled {
            let device = resolveCurrentCamera()
            attachCameraWithStabilization(device)
        }
        if config.audioEnabled {
            encoderBridge.attachAudio()
        }

        // Step 6: Configure SRT options if this is an SRT endpoint.
        // This passes the mode, passphrase, latency, and stream ID from the
        // profile to the bridge so they get baked into the SRT connection URL.
        // For RTMP bridges this is a no-op (default protocol extension).
        encoderBridge.configureSRTOptions(
            mode: profile.srtMode,
            passphrase: profile.srtPassphrase,
            latencyMs: profile.srtLatencyMs,
            streamId: profile.srtStreamId
        )

        // Step 7: Connect to the streaming server and start publishing.
        // The encoder bridge handles the protocol-specific details:
        // - HaishinKitEncoderBridge: opens an RTMP/RTMPS connection
        // - SRTEncoderBridge: opens an SRT socket connection
        encoderBridge.connect(url: profile.rtmpUrl, streamKey: profile.streamKey)

        // Step 7: Verify the connection succeeded, then go live.
        let connected = await waitForEncoderConnection(timeoutMs: 8_000)
        guard connected else {
            lastErrorMessage = "Unable to connect to the endpoint. Check URL/stream key and network, then try again."

            let snapshot = await coordinator.stopSession(reason: .errorNetwork)
            applySnapshot(snapshot)
            scheduleReturnToIdle()
            return
        }

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

        // If recording is active, finalize it before disconnecting.
        // This ensures the MP4 trailer (moov atom) is written properly
        // so the file isn't corrupted. We do this BEFORE disconnecting
        // the transport because the recorder needs the encoder pipeline
        // to still be alive to flush its last frames.
        if encoderBridge.isRecording {
            await stopRecording()
        }

        // Tell the encoder to stop sending data and disconnect.
        encoderBridge.detachCamera()
        encoderBridge.detachAudio()
        encoderBridge.disconnect()

        // Stop forwarding stats and reset the display to defaults.
        statsCancellable?.cancel()
        statsCancellable = nil
        streamStats = StreamStats()

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
            let snapshot = await coordinator.snapshot
            guard snapshot.media.videoActive else { return }

            guard let current = currentCameraDevice else { return }
            let next = nextCameraInCycle(after: current)

            encoderBridge.detachCamera()
            attachCameraWithStabilization(next)

            currentCameraDevice = next
            settingsRepository.setDefaultCameraDevice(next)
            settingsRepository.setDefaultCameraPosition(next.position)
        }
    }

    /// Switch to a specific camera device (used by long-press menu).
    func switchToCamera(_ device: CameraDevice) {
        Task {
            let snapshot = await coordinator.snapshot
            guard snapshot.media.videoActive else { return }

            encoderBridge.detachCamera()
            attachCameraWithStabilization(device)

            currentCameraDevice = device
            settingsRepository.setDefaultCameraDevice(device)
            settingsRepository.setDefaultCameraPosition(device.position)
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
                let device = resolveCurrentCamera()
                attachCameraWithStabilization(device)
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

    // MARK: - Local Recording

    /// Start recording the live stream to a local MP4 file.
    ///
    /// This method:
    ///   1. Checks that enough disk space is available (≥ 100 MB).
    ///   2. Generates a timestamped filename in the Recordings directory.
    ///   3. Transitions the recording state to `.starting`.
    ///   4. Tells the encoder bridge to begin writing frames to the file.
    ///   5. Transitions to `.recording` on success, or `.failed` on error.
    ///
    /// Recording uses the same encoded frames being sent to the server,
    /// so there is minimal additional CPU or battery overhead.
    func startRecording() async {
        // Step 1: Make sure we have enough disk space.
        guard RecordingFileManager.hasEnoughDiskSpace() else {
            let snapshot = await coordinator.updateRecording(
                .failed(reason: "Not enough disk space to start recording.")
            )
            applySnapshot(snapshot)
            lastErrorMessage = "Not enough disk space to start recording."
            return
        }

        // Step 2: Generate a unique filename.
        let fileURL = RecordingFileManager.generateFilename()

        // Step 3: Transition to .starting state so the UI knows we're setting up.
        let destination: RecordingDestination = settingsRepository.getRecordingDestination()
        let startingSnapshot = await coordinator.updateRecording(
            .starting(destination: destination)
        )
        applySnapshot(startingSnapshot)

        // Step 4: Tell the encoder bridge to start writing frames to disk.
        do {
            try await encoderBridge.startRecording(to: fileURL)

            // Step 5a: Success — transition to .recording.
            let recordingSnapshot = await coordinator.updateRecording(
                .recording(destination: destination)
            )
            applySnapshot(recordingSnapshot)
            print("[StreamingEngine] Recording started → \(fileURL.lastPathComponent)")
        } catch {
            // Step 5b: Failed — update state and show error to the user.
            let failedSnapshot = await coordinator.updateRecording(
                .failed(reason: error.localizedDescription)
            )
            applySnapshot(failedSnapshot)
            lastErrorMessage = "Failed to start recording: \(error.localizedDescription)"
            print("[StreamingEngine] Recording failed to start: \(error)")
        }
    }

    /// Stop the current recording and finalize the MP4 file.
    ///
    /// The recording state transitions through `.finalizing` while the
    /// MP4 trailer (moov atom) is written, then back to `.off` once complete.
    func stopRecording() async {
        // Transition to .finalizing so the UI shows a brief "saving" state.
        let finalizingSnapshot = await coordinator.updateRecording(.finalizing)
        applySnapshot(finalizingSnapshot)

        do {
            let outputURL = try await encoderBridge.stopRecording()

            // Back to .off — recording complete.
            let offSnapshot = await coordinator.updateRecording(.off)
            applySnapshot(offSnapshot)

            if let url = outputURL {
                print("[StreamingEngine] Recording saved → \(url.lastPathComponent)")
            }
        } catch {
            // If finalization fails, mark as failed so the user knows.
            let failedSnapshot = await coordinator.updateRecording(
                .failed(reason: error.localizedDescription)
            )
            applySnapshot(failedSnapshot)
            lastErrorMessage = "Failed to stop recording: \(error.localizedDescription)"
            print("[StreamingEngine] Recording failed to stop: \(error)")
        }
    }

    // MARK: - Preview

    /// Attach a UIView to display the live camera preview.
    func attachPreview(_ view: UIView) {
        // Remember the preview view so we can re-attach it if the bridge
        // is swapped later (e.g., when startStream creates a new bridge).
        currentPreviewView = view

        encoderBridge.attachPreview(view)

        // Show a live preview even before streaming starts.
        if shouldManageIdlePreviewCamera {
            let device = resolveCurrentCamera()
            attachCameraWithStabilization(device)
        }
    }

    /// Remove the camera preview from its parent view.
    func detachPreview() {
        currentPreviewView = nil

        encoderBridge.detachPreview()

        // If we're not actively streaming, release the camera when preview closes.
        if shouldManageIdlePreviewCamera {
            encoderBridge.detachCamera()
        }
    }

    private var shouldManageIdlePreviewCamera: Bool {
        switch sessionSnapshot.transport {
        case .idle, .stopped:
            return true
        default:
            return false
        }
    }

    // MARK: - Private Helpers

    // MARK: Camera Helpers

    /// Populate the camera device list from hardware and restore persisted choice.
    private func loadCameraDevices() {
        availableCameraDevices = capabilityQuery.availableCameraDevices()
        // Restore persisted camera, falling back to first available
        if let saved = settingsRepository.getDefaultCameraDevice(),
           availableCameraDevices.contains(saved) {
            currentCameraDevice = saved
        } else if let first = availableCameraDevices.first {
            currentCameraDevice = first
        }
    }

    /// Return the current camera device, falling back to a sensible default.
    private func resolveCurrentCamera() -> CameraDevice {
        if let device = currentCameraDevice { return device }
        let fallback = availableCameraDevices.first ?? CameraDevice.defaultBackWide
        currentCameraDevice = fallback
        return fallback
    }

    /// Alternate front/back cycling order:
    /// Back Wide → Front → Back Ultra Wide → Front → Back Telephoto → Front → …
    private func nextCameraInCycle(after current: CameraDevice) -> CameraDevice {
        let backs = availableCameraDevices.filter { $0.position == .back }
        let fronts = availableCameraDevices.filter { $0.position == .front }

        if current.position == .front {
            // Switch to next back camera after the last-used back camera
            if let lastBackIndex = backs.firstIndex(where: { $0 == lastUsedBackCamera }),
               lastBackIndex + 1 < backs.count {
                let next = backs[lastBackIndex + 1]
                lastUsedBackCamera = next
                return next
            }
            // Wrap around to first back camera
            if let first = backs.first {
                lastUsedBackCamera = first
                return first
            }
            // No back cameras — stay on front
            return current
        } else {
            // Currently on a back camera — switch to front
            lastUsedBackCamera = current
            return fronts.first ?? current
        }
    }

    /// Tracks which back camera was last used for cycling purposes.
    private var lastUsedBackCamera: CameraDevice?

    /// Attach a camera and apply the user's stabilization preference.
    private func attachCameraWithStabilization(_ device: CameraDevice) {
        encoderBridge.attachCamera(device: device.avCaptureDevice())
        let stabMode = settingsRepository.getVideoStabilizationMode()
        if stabMode != .off {
            encoderBridge.setVideoStabilization(stabMode)
        }
    }

    /// Build a StreamConfig from user settings and the given profile ID.
    /// This gathers all the settings the user has configured (resolution,
    /// bitrate, etc.) into one convenient struct.
    private func buildStreamConfig(profileId: String, profile: EndpointProfile) -> StreamConfig {
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
            // Pass the codec from the endpoint profile so codec-specific
            // ABR ladders use the correct bitrate targets for H.264/H.265/AV1.
            videoCodec: profile.videoCodec,
            abrEnabled: settingsRepository.isAbrEnabled(),
            localRecordingEnabled: settingsRepository.isLocalRecordingEnabled(),
            recordToPhotosLibrary: settingsRepository.getRecordingDestination() == .photosLibrary
        )
    }

    /// Copy the coordinator's snapshot to our @Published property.
    /// Because we're @MainActor, this triggers SwiftUI to re-render any
    /// observing views.
    ///
    /// This method also manages the device idle timer (auto-lock).
    /// When we go live, we disable the idle timer so the screen stays on —
    /// a user who is streaming doesn't want their phone to auto-lock and
    /// interrupt the broadcast. When the stream stops (or returns to idle),
    /// we re-enable the idle timer so normal auto-lock behavior resumes.
    private func applySnapshot(_ snapshot: StreamSessionSnapshot) {
        // Detect when the transport state changes so we can toggle the
        // idle timer only on actual transitions, not on every snapshot.
        let previousTransport = self.sessionSnapshot.transport
        self.sessionSnapshot = snapshot

        // --- Keep Screen On (Android parity: FLAG_KEEP_SCREEN_ON) ---
        //
        // Why? During a live stream the screen must stay on. If iOS
        // auto-locks, the camera stops, the RTMP connection drops, and
        // the stream is ruined. Setting isIdleTimerDisabled = true tells
        // iOS "don't turn the screen off while we're working."
        //
        // We only flip the flag when the transport *changes* to avoid
        // redundant UIApplication calls on every snapshot update.
        switch snapshot.transport {
        case .live:
            // Stream is live → keep the screen on.
            if previousTransport != .live {
                UIApplication.shared.isIdleTimerDisabled = true
            }

        case .idle, .stopped:
            // Stream ended or reset → allow the screen to auto-lock again.
            // We check the previous state to avoid toggling on every idle
            // snapshot (e.g., the initial app-launch snapshot is already idle).
            if case .live = previousTransport {
                UIApplication.shared.isIdleTimerDisabled = false
            } else if case .reconnecting = previousTransport {
                UIApplication.shared.isIdleTimerDisabled = false
            } else if case .stopping = previousTransport {
                UIApplication.shared.isIdleTimerDisabled = false
            }

        default:
            // For .connecting, .reconnecting, .stopping — leave the flag
            // as-is. If we were live and are now reconnecting, we still
            // want the screen to stay on.
            break
        }
    }

    private func waitForEncoderConnection(timeoutMs: Int) async -> Bool {
        if encoderBridge.isConnected {
            return true
        }

        let stepNs: UInt64 = 250_000_000
        let maxAttempts = max(1, timeoutMs / 250)
        for _ in 0..<maxAttempts {
            if encoderBridge.isConnected {
                return true
            }
            try? await Task.sleep(nanoseconds: stepNs)
        }

        return encoderBridge.isConnected
    }

    /// Subscribe to the current encoder bridge's stats publisher and forward
    /// every update to our own `@Published streamStats`. This wires the
    /// bridge's 1-second stat timer to the ViewModel → HUD display chain.
    private func bindBridgeStats() {
        statsCancellable?.cancel()
        statsCancellable = encoderBridge.statsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                self?.streamStats = stats
            }
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

    // MARK: - Recording State

    /// Update the local recording state in the session snapshot.
    ///
    /// Called by the engine when recording starts, stops, or fails.
    ///
    /// - Parameter state: The new recording state.
    /// - Returns: The updated snapshot with the new recording state.
    func updateRecording(_ state: RecordingState) -> StreamSessionSnapshot {
        snapshot.recording = state
        return snapshot
    }
}
