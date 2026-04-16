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

    /// `true` when the camera preview is attached and showing a live feed.
    /// This is separate from `TransportState` because the preview lifecycle
    /// is tied to the view hierarchy, not the network connection.
    @Published private(set) var isPreviewing: Bool = false

    /// Metadata about the endpoint profile currently being streamed to.
    /// Set when a stream starts, cleared when it stops.
    @Published private(set) var activeProfileName: String?
    @Published private(set) var activeProtocol: StreamProtocol?
    @Published private(set) var activeVideoCodec: VideoCodec?
    /// Badge text for the protocol, distinguishing "RTMP" from "RTMPS".
    @Published private(set) var activeProtocolBadge: String?

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

    /// Handle for the delayed "return to idle" task spawned by `stopStream()`.
    ///
    /// We store this so `startStream()` can cancel it if the user starts
    /// a new stream before the 2-second delay expires. Without cancellation,
    /// the delayed task could overwrite the new stream's state back to idle.
    private var idleReturnTask: Task<Void, Never>?

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

    /// Manages the connection lifecycle: detecting network drops and
    /// coordinating automatic reconnection with exponential backoff.
    ///
    /// The engine wires up `onConnectionEvent` to receive notifications
    /// when the network changes or when it's time to attempt a reconnect.
    /// Created fresh for each streaming session (via `DependencyContainer`)
    /// because `NWPathMonitor.cancel()` is terminal — once cancelled, the
    /// same monitor instance cannot be restarted.
    private var connectionManager: ConnectionManager

    /// Subscription that monitors `encoderBridge.isConnectedPublisher`
    /// during live streaming to detect connection drops.
    ///
    /// When `isConnected` transitions from `true` to `false` while in the
    /// `.live` transport state, the engine initiates a reconnection sequence
    /// through `ConnectionManager`.
    ///
    /// **Current limitation:** The bridges only flip `isConnected` in their
    /// own connect/disconnect/release methods — not from HaishinKit/SRT
    /// transport callbacks. Server-initiated drops are detected via
    /// `NWPathMonitor` (network-level) rather than transport-level callbacks.
    private var connectionDropCancellable: AnyCancellable?

    /// The URL and stream key of the profile currently being streamed to.
    /// Stored when a stream starts so the reconnection flow can re-connect
    /// with the same credentials without re-resolving the profile.
    private var activeConnectionURL: String?
    private var activeConnectionStreamKey: String?

    /// The maximum number of reconnection attempts configured by the user.
    /// Read from `settingsRepository` when monitoring starts. Stored so
    /// the engine can include it in `TransportState.reconnecting` events
    /// and the UI can show "attempt 3 of 10".
    private var activeReconnectMaxAttempts: Int = 10

    /// All camera devices on this hardware, ordered for cycling.
    private(set) var availableCameraDevices: [CameraDevice] = []

    /// The camera currently in use (persisted across sessions).
    private(set) var currentCameraDevice: CameraDevice?

    // MARK: - Endpoint Profile Access

    /// All configured endpoint profiles. Used by the UI for endpoint selection.
    func getEndpointProfiles() -> [EndpointProfile] {
        profileRepository.getAll()
    }

    /// The currently selected default endpoint profile.
    func getDefaultProfile() -> EndpointProfile? {
        profileRepository.getDefault() ?? profileRepository.getAll().first
    }

    /// Set a profile as the default endpoint for future streams.
    func setDefaultProfile(_ profileId: String) {
        guard let profile = profileRepository.getById(profileId) else { return }
        try? profileRepository.setDefault(profile)
    }

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
        self.connectionManager = container.connectionManager
        loadCameraDevices()
        observeDeviceOrientation()
    }

    /// Internal init used for testing — lets us inject mock dependencies.
    init(
        encoderBridge: EncoderBridge,
        profileRepository: EndpointProfileRepository,
        settingsRepository: SettingsRepository,
        audioSessionManager: AudioSessionManagerProtocol,
        capabilityQuery: DeviceCapabilityQuery? = nil,
        connectionManager: ConnectionManager? = nil
    ) {
        self.encoderBridge = encoderBridge
        self.profileRepository = profileRepository
        self.settingsRepository = settingsRepository
        self.audioSessionManager = audioSessionManager
        self.capabilityQuery = capabilityQuery ?? AVDeviceCapabilityQuery()
        self.connectionManager = connectionManager ?? ConnectionManager()
        loadCameraDevices()
        observeDeviceOrientation()
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
        // Cancel any pending "return to idle" task from a previous stopStream().
        // If the user starts a new stream before the 2-second delay expires,
        // we don't want the delayed task to reset state back to idle and
        // overwrite our new stream's state.
        idleReturnTask?.cancel()
        idleReturnTask = nil

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

        // Capture active profile metadata so the HUD can display it.
        activeProfileName = profile.name
        activeProtocol = profile.detectedProtocol
        activeVideoCodec = profile.videoCodec
        // Derive badge text: "RTMPS" for rtmps:// URLs, otherwise protocol display name.
        let urlLower = profile.rtmpUrl.lowercased().trimmingCharacters(in: .whitespaces)
        if urlLower.hasPrefix("rtmps://") {
            activeProtocolBadge = "RTMPS"
        } else if urlLower.hasPrefix("srt://") {
            activeProtocolBadge = "SRT"
        } else {
            activeProtocolBadge = "RTMP"
        }

        // Step 2b: Create the correct encoder bridge for this profile's protocol.
        // The factory inspects the URL scheme (rtmp:// vs srt://) and returns
        // either an HaishinKitEncoderBridge or SRTEncoderBridge.
        // We create a NEW bridge each time so leftover state from a previous
        // stream (e.g., an RTMP connection) doesn't interfere with a new one
        // (e.g., SRT). This also means switching endpoints between RTMP and
        // SRT "just works" — no need to manually clean up the old bridge.

        // Fully release the old bridge before creating a new one.
        // This is a safety net — stopStream() should have already called
        // release(), but if the user starts a new stream very quickly or
        // stopStream() was skipped, this ensures the old bridge's mixer
        // and SRT/RTMP sockets are fully shut down before we create a
        // fresh bridge. Without this, two MediaMixer instances would
        // compete for camera hardware and SRT sockets could conflict.
        await encoderBridge.release()

        self.encoderBridge = EncoderBridgeFactory.makeBridge(for: profile)

        // Subscribe to the new bridge's stats so the HUD updates in real time.
        bindBridgeStats()

        // Re-attach the preview view to the NEW bridge so the user sees
        // the live camera feed. Without this, the preview stays wired to
        // the old (now-discarded) bridge and the screen goes black.
        if let previewView = currentPreviewView {
            encoderBridge.attachPreview(previewView)
        }

        // Sync the new bridge's orientation to match the current effective
        // orientation (respects auto/portrait/landscape preference).
        // Without this, the new bridge defaults to .portrait regardless
        // of the actual device orientation.
        lastAppliedOrientation = nil  // Force reapply on new bridge
        applyEffectiveOrientation()

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

            // The new bridge (created at line 274) has the camera and audio
            // attached but the connection never started. We must release it
            // so its AVCaptureSession doesn't keep running and block future
            // bridges from accessing the camera hardware.
            encoderBridge.detachCamera()
            encoderBridge.detachAudio()
            await encoderBridge.release()

            // Revive the idle preview so the user sees a live camera feed
            // instead of a frozen frame from the failed stream attempt.
            await reviveIdlePreview()

            // Clean up stats and metadata the same way stopStream() does.
            // Without this, stale profile info lingers in the UI.
            statsCancellable?.cancel()
            statsCancellable = nil
            streamStats = StreamStats()
            activeProfileName = nil
            activeProtocol = nil
            activeVideoCodec = nil
            activeProtocolBadge = nil
            activeConnectionURL = nil
            activeConnectionStreamKey = nil

            // If encoder setup fails, stop with an encoder error.
            let snapshot = await coordinator.stopSession(reason: .errorEncoder)
            applySnapshot(snapshot)
            scheduleReturnToIdle()
            return
        }

        // Step 5: Attach camera and audio.
        if config.videoEnabled {
            let device = resolveCurrentCamera()
            await attachCameraWithStabilization(device)
            // Re-apply orientation after camera attach — attaching a new
            // camera creates a fresh AVCaptureConnection which defaults
            // to .portrait, overriding what we set after bridge swap.
            lastAppliedOrientation = nil
            applyEffectiveOrientation()
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

            // The bridge has camera, audio, and a potentially-hanging connect
            // Task attached. Release everything so the AVCaptureSession stops
            // and the dangling connect Task is cancelled. This mirrors exactly
            // what stopStream() does on a normal shutdown.
            encoderBridge.detachCamera()
            encoderBridge.detachAudio()
            await encoderBridge.release()

            // Revive the idle preview so the user sees live camera output
            // instead of a frozen frame from the failed connection attempt.
            await reviveIdlePreview()

            // Clean up stats and metadata the same way stopStream() does.
            // Without this, stale profile info lingers in the UI.
            statsCancellable?.cancel()
            statsCancellable = nil
            streamStats = StreamStats()
            activeProfileName = nil
            activeProtocol = nil
            activeVideoCodec = nil
            activeProtocolBadge = nil
            activeConnectionURL = nil
            activeConnectionStreamKey = nil

            let snapshot = await coordinator.stopSession(reason: .errorNetwork)
            applySnapshot(snapshot)
            scheduleReturnToIdle()
            return
        }

        let currentToken = await coordinator.currentSessionToken
        let liveSnapshot = await coordinator.goLive(sessionToken: currentToken)
        applySnapshot(liveSnapshot)

        // Store connection credentials so reconnection can reuse them
        // without re-resolving the profile from the repository.
        activeConnectionURL = profile.rtmpUrl
        activeConnectionStreamKey = profile.streamKey

        // Start network monitoring and wire up the reconnection handler.
        // ConnectionManager uses NWPathMonitor to detect Wi-Fi/cellular
        // changes and exponential backoff for retry timing.
        startConnectionMonitoring()
    }

    /// Stop the current stream gracefully.
    ///
    /// This method is **idempotent** — calling it when already idle is a no-op.
    /// It disconnects the encoder bridge, transitions state to .stopped,
    /// and then returns to .idle after a brief delay.
    ///
    /// After releasing the old bridge, a fresh bridge is created immediately
    /// so the camera preview comes back to life. Without this, the MTHKView
    /// would show a frozen last frame until the user navigated away and back.
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

        // Stop connection monitoring and cancel any pending reconnect attempts.
        // This must happen BEFORE release() so the ConnectionManager doesn't
        // try to trigger a reconnect while we're tearing down.
        stopConnectionMonitoring()

        // Tell the encoder to stop sending data and fully release all resources.
        // `release()` is async because it must await the MediaMixer shutdown
        // and SRT/RTMP socket closure. Without awaiting this, the old bridge's
        // AVCaptureSession stays running and blocks the next bridge from
        // accessing the camera — this was the root cause of SRT reconnection
        // failures.
        encoderBridge.detachCamera()
        encoderBridge.detachAudio()
        await encoderBridge.release()

        // Immediately revive the camera preview so the user sees a live feed
        // instead of a frozen last frame. This creates a fresh encoder bridge
        // with a running mixer, re-attaches the preview view, re-attaches the
        // camera, and applies the correct orientation.
        await reviveIdlePreview()

        // Stop forwarding stats and reset the display to defaults.
        statsCancellable?.cancel()
        statsCancellable = nil
        streamStats = StreamStats()

        // Clear active profile metadata.
        activeProfileName = nil
        activeProtocol = nil
        activeVideoCodec = nil
        activeProtocolBadge = nil
        activeConnectionURL = nil
        activeConnectionStreamKey = nil

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
            guard snapshot.media.videoActive || shouldManageIdlePreviewCamera else { return }

            guard let current = currentCameraDevice else { return }
            let next = nextCameraInCycle(after: current)

            encoderBridge.detachCamera()
            await attachCameraWithStabilization(next)

            // New camera = new capture connection with default orientation.
            lastAppliedOrientation = nil
            applyEffectiveOrientation()

            currentCameraDevice = next
            settingsRepository.setDefaultCameraDevice(next)
            settingsRepository.setDefaultCameraPosition(next.position)
        }
    }

    /// Switch to a specific camera device (used by long-press menu).
    func switchToCamera(_ device: CameraDevice) {
        Task {
            let snapshot = await coordinator.snapshot
            guard snapshot.media.videoActive || shouldManageIdlePreviewCamera else { return }

            encoderBridge.detachCamera()
            await attachCameraWithStabilization(device)

            // New camera = new capture connection with default orientation.
            lastAppliedOrientation = nil
            applyEffectiveOrientation()

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
                await attachCameraWithStabilization(device)
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
        isPreviewing = true

        encoderBridge.attachPreview(view)

        // Apply the user's orientation preference now that the scene is
        // definitely active. This is the reliable place to enforce
        // portrait/landscape mode on launch (init may be too early).
        applyIdleOrientationMask()

        // Show a live preview even before streaming starts.
        if shouldManageIdlePreviewCamera {
            let device = resolveCurrentCamera()
            Task {
                await attachCameraWithStabilization(device)
                // Re-apply orientation after camera attach, since attaching
                // a new camera may reset the capture connection's orientation.
                applyEffectiveOrientation()
            }
        }
    }

    /// Remove the camera preview from its parent view.
    func detachPreview() {
        currentPreviewView = nil
        isPreviewing = false

        encoderBridge.detachPreview()

        // If we're not actively streaming, release the camera when preview closes.
        if shouldManageIdlePreviewCamera {
            encoderBridge.detachCamera()
        }
    }

    // MARK: - Connection Monitoring & Reconnection

    /// Start monitoring the network and encoder connection for drops.
    ///
    /// Called after going live in `startStream()`. This sets up two
    /// independent detection mechanisms:
    ///
    /// 1. **NWPathMonitor** (via `ConnectionManager`) — detects OS-level
    ///    network changes (Wi-Fi disconnect, cellular handoff, airplane mode).
    ///    This is the most reliable way to detect network loss on iOS.
    ///
    /// 2. **isConnectedPublisher** — monitors the encoder bridge's connection
    ///    state. If `isConnected` transitions from `true` to `false` while
    ///    we're live, it means the transport layer dropped.
    ///
    /// **Current limitation:** The bridges only flip `isConnected` in their
    /// own connect/disconnect/release methods. They don't yet listen to
    /// HaishinKit/SRT transport-level disconnect callbacks, so server-initiated
    /// drops (e.g., server restart) won't be detected through this path.
    /// Network-level drops ARE detected via NWPathMonitor.
    private func startConnectionMonitoring() {
        // Read the user's configured max reconnect attempts from settings.
        // This is stored so we can include it in TransportState.reconnecting
        // events — the UI needs it to show "attempt 3 of 10".
        activeReconnectMaxAttempts = settingsRepository.getReconnectMaxAttempts()

        // Create a fresh ConnectionManager with a policy that respects
        // the user's configured max attempts. We create a new one each time
        // because NWPathMonitor.cancel() is terminal — once cancelled, the
        // same monitor instance cannot be restarted.
        connectionManager = ConnectionManager(
            reconnectPolicy: ExponentialBackoffReconnectPolicy(
                maxAttempts: activeReconnectMaxAttempts
            )
        )

        // Wire up the ConnectionManager's event callback.
        // These events arrive from a background queue, so we dispatch
        // to the main actor for thread safety (the engine is @MainActor).
        connectionManager.onConnectionEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleConnectionEvent(event)
            }
        }

        // Start NWPathMonitor to watch for network connectivity changes.
        connectionManager.startMonitoring()

        // Subscribe to the bridge's connection state. If it drops from
        // true → false while we're in .live state, trigger reconnection.
        connectionDropCancellable = encoderBridge.isConnectedPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleBridgeConnectionChange(connected)
                }
            }
    }

    /// Stop monitoring and cancel any pending reconnection attempts.
    ///
    /// Called by `stopStream()` before releasing the bridge. This ensures
    /// the ConnectionManager doesn't try to trigger a reconnect while we're
    /// tearing down the bridge.
    private func stopConnectionMonitoring() {
        // Cancel the isConnected subscription so bridge state changes
        // during release() don't trigger reconnection.
        connectionDropCancellable?.cancel()
        connectionDropCancellable = nil

        // Stop the NWPathMonitor and cancel any pending reconnect timers.
        connectionManager.cancelReconnect()
        connectionManager.stopMonitoring()

        // Clear the event callback to break the retain cycle.
        connectionManager.onConnectionEvent = nil

        // Create a fresh ConnectionManager for the next streaming session.
        // NWPathMonitor.cancel() is terminal — once cancelled, the same
        // monitor instance cannot be restarted. So we replace the entire
        // ConnectionManager to get a fresh NWPathMonitor.
        // startConnectionMonitoring() will replace this again with the
        // user's configured maxAttempts, so we use a default policy here.
        connectionManager = ConnectionManager()
    }

    /// Handle a connection event from the ConnectionManager.
    ///
    /// The ConnectionManager emits events for network changes and reconnect
    /// timing. The engine translates these into state transitions:
    ///
    /// - `.reconnecting(attempt, ms)` — Update the transport state to
    ///   `.reconnecting` so the UI shows the retry count and wait time.
    /// - `.connected` (misleadingly named — means "time to retry") —
    ///   Attempt to reconnect using the stored URL and stream key.
    /// - `.disconnected(reason)` — Retries exhausted or auth failure.
    ///   Stop the stream with the given reason.
    /// - `.networkAvailable` / `.networkUnavailable` — Informational.
    ///   Network restoration triggers an immediate retry inside
    ///   ConnectionManager (handled internally).
    private func handleConnectionEvent(_ event: ConnectionManager.ConnectionEvent) async {
        switch event {
        case .reconnecting(let attempt, let nextRetryMs):
            // Update the transport state so the UI shows "Reconnecting…"
            // with the attempt count, max attempts, and estimated wait time.
            let snapshot = await coordinator.updateTransport(
                .reconnecting(
                    attempt: attempt,
                    maxAttempts: activeReconnectMaxAttempts,
                    nextRetryMs: Int64(nextRetryMs)
                )
            )
            applySnapshot(snapshot)

        case .connected:
            // ConnectionManager says "try now" — attempt to reconnect
            // using the same URL and stream key from the current session.
            await attemptReconnect()

        case .disconnected(let reason):
            // Retries exhausted or auth failure. Stop the stream entirely.
            // This will clean up monitoring, release the bridge, and
            // transition to .stopped → .idle.
            await stopStream(reason: reason)

        case .networkAvailable:
            // NWPathMonitor detected network restoration. ConnectionManager
            // handles this internally by cancelling the current timer and
            // scheduling an immediate retry. Nothing for the engine to do.
            break

        case .networkUnavailable:
            // Network dropped. The actual reconnection is triggered by
            // handleBridgeConnectionChange() when isConnected goes false,
            // or by NWPathMonitor → ConnectionManager's internal handling.
            // We don't start reconnection here because NWPathMonitor is
            // advisory — a transient path change doesn't always mean the
            // stream is dead.
            break
        }
    }

    /// React to the encoder bridge's connection state changing.
    ///
    /// If the connection drops from `true` to `false` while we're in the
    /// `.live` transport state, this triggers the reconnection sequence
    /// through `ConnectionManager`.
    ///
    /// - Parameter connected: The new connection state from the bridge.
    private func handleBridgeConnectionChange(_ connected: Bool) async {
        // Only care about drops during live streaming.
        let transport = await coordinator.snapshot.transport
        guard !connected, transport == .live else { return }

        // The connection dropped while we were live. Start the reconnection
        // sequence — ConnectionManager will calculate delays and emit
        // .reconnecting events until success or max retries reached.
        connectionManager.handleConnectionFailure(reason: .errorNetwork)
    }

    /// Attempt to re-establish the connection during a reconnect sequence.
    ///
    /// Called by `handleConnectionEvent(.connected)` when the ConnectionManager
    /// decides it's time to try again. This reuses the existing bridge
    /// (no new bridge creation) and calls disconnect → connect with the
    /// stored URL and stream key.
    ///
    /// If the reconnection succeeds (bridge becomes connected within 8s),
    /// the ConnectionManager's reconnect loop is cancelled and the engine
    /// returns to `.live` state. If it fails, the ConnectionManager will
    /// schedule another attempt (up to its max retry count).
    private func attemptReconnect() async {
        guard let url = activeConnectionURL,
              let streamKey = activeConnectionStreamKey else {
            // No stored credentials — can't reconnect. Stop the stream.
            await stopStream(reason: .errorNetwork)
            return
        }

        // Disconnect the old transport before reconnecting.
        // This ensures the SRT/RTMP socket is properly closed before
        // we open a new one. Note: disconnect() is fire-and-forget,
        // but the bridge's connect() creates a new Task so there's
        // no strict ordering requirement on the socket close.
        encoderBridge.disconnect()

        // Small delay to let the disconnect propagate through the bridge.
        // Without this, the new connect() might race with the old socket
        // teardown. 500ms is enough for SRT/RTMP socket shutdown.
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Attempt reconnection with the same URL and stream key.
        encoderBridge.connect(url: url, streamKey: streamKey)

        // Wait for the connection to succeed (same timeout as initial connect).
        let reconnected = await waitForEncoderConnection(timeoutMs: 8_000)

        if reconnected {
            // Success! Cancel the reconnect loop and return to .live state.
            connectionManager.cancelReconnect()

            let token = await coordinator.currentSessionToken
            let snapshot = await coordinator.goLive(sessionToken: token)
            applySnapshot(snapshot)

            // Request a keyframe so new viewers / the server can decode
            // immediately without waiting for the next natural I-frame.
            await encoderBridge.requestKeyFrame()
        }
        // If reconnection failed, do nothing here — the ConnectionManager
        // will schedule the next attempt and emit another .reconnecting event.
    }

    /// Revive the camera preview after a stream stops.
    ///
    /// **Why this is needed:**
    /// When `stopStream()` calls `release()`, the encoder bridge's MediaMixer
    /// shuts down — which means the MTHKView (Metal preview) stops receiving
    /// camera frames and freezes on the last rendered frame. The bridge is
    /// essentially dead at that point: its AVCaptureSession is stopped, the
    /// preview is detached from the mixer, and orientation changes have no
    /// effect.
    ///
    /// **What this method does:**
    /// 1. Checks if the preview view still exists (it's a weak reference and
    ///    SwiftUI may have dismantled it). If it's gone, marks `isPreviewing`
    ///    as `false` and returns early — no point starting a mixer with no UI.
    /// 2. Creates a fresh `HaishinKitEncoderBridge`. Each bridge's `init()`
    ///    automatically starts its MediaMixer (and AVCaptureSession), so we
    ///    get a running capture pipeline for free.
    /// 3. Assigns the new bridge to `self.encoderBridge`.
    /// 4. Attaches the existing preview view to the new bridge's mixer so
    ///    the MTHKView starts receiving live frames again.
    /// 5. Re-attaches the camera hardware with the user's stabilization pref.
    /// 6. Resets and re-applies the video orientation so the preview matches
    ///    the current device orientation (portrait/landscape/auto).
    ///
    /// **Why a fresh bridge instead of restarting the old one?**
    /// The bridge's `init()` already wires up mixer → stream outputs and calls
    /// `mixer.startRunning()`. Creating a new instance reuses this proven init
    /// path. Adding a "restart" method would require new protocol surface area
    /// and duplicate the init logic — more risk, no benefit.
    ///
    /// **Thread safety:**
    /// This method is called on the `@MainActor` (the engine is `@MainActor`).
    /// We capture the new bridge in a local variable and verify it's still the
    /// current bridge after each `await` point, guarding against races where
    /// `startStream()` might swap the bridge while we're awaiting camera setup.
    private func reviveIdlePreview() async {
        // If the preview view has been deallocated (SwiftUI dismantled it),
        // there's nothing to revive. Mark isPreviewing as false so the UI
        // state is accurate.
        guard let previewView = currentPreviewView else {
            isPreviewing = false
            return
        }

        // Create a fresh bridge with a running mixer. The protocol type
        // doesn't matter for idle preview — we just need a capture pipeline.
        // HaishinKitEncoderBridge is the default (RTMP), and its init()
        // starts the mixer automatically.
        let newBridge = HaishinKitEncoderBridge()
        self.encoderBridge = newBridge

        // Wire the preview view to the new bridge's mixer so the MTHKView
        // starts receiving live camera frames again (instead of showing the
        // frozen last frame from the ended stream).
        newBridge.attachPreview(previewView)
        isPreviewing = true

        // Re-attach the camera so the mixer has a video source.
        // We check that the bridge hasn't been swapped by startStream()
        // during the await — if it was, our work here is stale and we bail.
        let device = resolveCurrentCamera()
        await attachCameraWithStabilization(device)

        // Safety check: if startStream() replaced the bridge while we were
        // awaiting camera attachment, don't apply orientation to the wrong
        // bridge.
        guard self.encoderBridge === newBridge else { return }

        // Reset orientation tracking and apply the correct orientation for
        // the current device position. Without this, the preview would use
        // whatever orientation was last set on the old (now-dead) bridge.
        lastAppliedOrientation = nil
        applyEffectiveOrientation()
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

    /// Cycle to the next camera in enumeration order (wraps around).
    /// Order: back cameras (ultra-wide → wide → telephoto), then front.
    private func nextCameraInCycle(after current: CameraDevice) -> CameraDevice {
        guard availableCameraDevices.count > 1 else { return current }
        guard let index = availableCameraDevices.firstIndex(of: current) else {
            return availableCameraDevices.first ?? current
        }
        return availableCameraDevices[(index + 1) % availableCameraDevices.count]
    }

    /// Observation token for device orientation changes. Cancelled on deinit.
    private var orientationObserver: NSObjectProtocol?

    /// Attach a camera and apply the user's stabilization preference.
    private func attachCameraWithStabilization(_ device: CameraDevice) async {
        await encoderBridge.attachCamera(device: device.avCaptureDevice())
        let stabMode = settingsRepository.getVideoStabilizationMode()
        if stabMode != .off {
            encoderBridge.setVideoStabilization(stabMode)
        }
    }

    // MARK: Orientation Helpers

    /// The last orientation we applied to the encoder bridge.
    /// Used to deduplicate — we skip if the orientation hasn't changed.
    private var lastAppliedOrientation: AVCaptureVideoOrientation?

    /// Start observing device orientation changes and forward them to the
    /// encoder bridge so the capture pipeline rotates frames correctly.
    ///
    /// Without this, HaishinKit defaults to `.portrait` and landscape
    /// preview just crops/zooms portrait frames.
    private func observeDeviceOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleOrientationChange()
            }
        }
    }

    /// Handle a device orientation change notification.
    ///
    /// During streaming the orientation is locked — we skip.
    /// In portrait/landscape mode, we force the locked orientation
    /// regardless of physical device position.
    /// In auto mode, we derive from the actual device orientation.
    ///
    /// No debounce — on iOS, setting AVCaptureConnection.videoOrientation
    /// is instant (unlike Android which must restart the camera preview).
    /// We deduplicate via `lastAppliedOrientation` instead.
    private func handleOrientationChange() {
        let transport = sessionSnapshot.transport
        switch transport {
        case .idle, .stopped:
            break // Allow orientation update
        default:
            // During streaming (connecting/live/reconnecting/stopping),
            // orientation is locked — skip.
            return
        }

        applyEffectiveOrientation()
    }

    /// The single source of truth for what orientation the capture pipeline
    /// should use right now.
    ///
    /// Checks the user's orientation preference:
    /// - **Portrait:** always `.portrait`
    /// - **Landscape:** uses the current interface orientation direction
    ///   (left or right) so the correct landscape variant is applied
    /// - **Auto:** derives from the current device/interface orientation
    ///
    /// Deduplicates by skipping if the orientation hasn't changed.
    /// Call this from any place that needs to ensure orientation is correct:
    /// `handleOrientationChange`, `attachPreview`, after bridge swap, after
    /// camera attach.
    func applyEffectiveOrientation() {
        let mode = settingsRepository.getOrientationMode()
        let orientation: AVCaptureVideoOrientation

        switch mode {
        case "portrait":
            orientation = .portrait
        case "landscape":
            // Use interface orientation to pick the correct landscape direction,
            // rather than hard-coding landscapeRight which would be wrong when
            // the device is in landscape-left.
            orientation = Self.currentLandscapeCaptureOrientation()
        default:
            // Auto mode — derive from current device/interface orientation.
            guard let detected = Self.detectCurrentCaptureOrientation() else {
                return
            }
            orientation = detected
        }

        // Deduplicate — skip if orientation hasn't changed.
        guard orientation != lastAppliedOrientation else { return }
        lastAppliedOrientation = orientation

        encoderBridge.setVideoOrientation(orientation)
    }

    /// Apply the user's idle orientation mask to the AppDelegate.
    ///
    /// In Auto mode, unlocks rotation (`.allButUpsideDown`).
    /// In Portrait/Landscape mode, locks to that orientation.
    /// Also syncs the capture orientation to match.
    ///
    /// Call this when transitioning back to idle/stopped, and on app launch
    /// (once a scene is available) so the user's preference is enforced.
    private func applyIdleOrientationMask() {
        let mask = OrientationManager.idleMask(settings: settingsRepository)
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            return
        }
        appDelegate.lockOrientation(mask)

        // Also sync capture orientation to match the user's preference.
        lastAppliedOrientation = nil
        applyEffectiveOrientation()
    }

    /// Detect the current capture orientation from the best available source.
    ///
    /// Prefers `windowScene.interfaceOrientation` (reliable even at launch)
    /// over `UIDevice.current.orientation` (can be `.unknown`/`.faceUp`).
    /// Returns `nil` only if no meaningful orientation can be determined.
    static func detectCurrentCaptureOrientation() -> AVCaptureVideoOrientation? {
        // Prefer interface orientation — it's always set to a usable value,
        // even at launch when UIDevice.orientation is still .unknown.
        if let sceneOrientation = currentInterfaceOrientation() {
            return captureOrientation(fromInterface: sceneOrientation)
        }

        // Fall back to device orientation.
        let device = UIDevice.current.orientation
        return captureOrientation(from: device)
    }

    /// Get the current landscape capture orientation, preferring the actual
    /// interface direction. Falls back to `.landscapeRight` if we can't tell.
    static func currentLandscapeCaptureOrientation() -> AVCaptureVideoOrientation {
        if let iface = currentInterfaceOrientation() {
            switch iface {
            case .landscapeLeft:  return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: break
            }
        }
        // Device might still be in portrait while user chose landscape mode.
        // Default to landscapeRight (home button on right / volume buttons on top).
        return .landscapeRight
    }

    /// Get the active window scene's interface orientation, if available.
    static func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation
    }

    /// Convert a `UIDeviceOrientation` to the matching
    /// `AVCaptureVideoOrientation`.
    ///
    /// Returns `nil` for orientations that don't have a direct mapping
    /// (face-up, face-down, unknown).
    ///
    /// Note: `landscapeLeft` and `landscapeRight` are intentionally
    /// swapped because UIDevice and AVCapture use opposite conventions.
    static func captureOrientation(
        from deviceOrientation: UIDeviceOrientation
    ) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .portrait:            return .portrait
        case .portraitUpsideDown:   return .portraitUpsideDown
        case .landscapeLeft:        return .landscapeRight
        case .landscapeRight:       return .landscapeLeft
        default:                    return nil
        }
    }

    /// Convert a `UIInterfaceOrientation` to the matching
    /// `AVCaptureVideoOrientation`.
    ///
    /// Unlike `UIDeviceOrientation`, `UIInterfaceOrientation` uses the
    /// **same** left/right convention as `AVCaptureVideoOrientation`,
    /// so no swap is needed.
    static func captureOrientation(
        fromInterface orientation: UIInterfaceOrientation
    ) -> AVCaptureVideoOrientation? {
        switch orientation {
        case .portrait:            return .portrait
        case .portraitUpsideDown:   return .portraitUpsideDown
        case .landscapeLeft:       return .landscapeLeft
        case .landscapeRight:      return .landscapeRight
        default:                   return nil
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
                OrientationManager.lockToPreferredOrientation(
                    settings: settingsRepository
                )
            }

        case .idle, .stopped:
            // Stream ended or reset → allow the screen to auto-lock again.
            // We check the previous state to avoid toggling on every idle
            // snapshot (e.g., the initial app-launch snapshot is already idle).
            if case .live = previousTransport {
                UIApplication.shared.isIdleTimerDisabled = false
                applyIdleOrientationMask()
            } else if case .reconnecting = previousTransport {
                UIApplication.shared.isIdleTimerDisabled = false
                applyIdleOrientationMask()
            } else if case .stopping = previousTransport {
                UIApplication.shared.isIdleTimerDisabled = false
                applyIdleOrientationMask()
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
    ///
    /// The task handle is stored in `idleReturnTask` so that
    /// `startStream()` can cancel it if the user starts a new stream
    /// before the delay expires.
    private func scheduleReturnToIdle() {
        idleReturnTask?.cancel()
        idleReturnTask = Task {
            // Capture the current session token to guard against races.
            // If the user starts a new stream within the 2-second window,
            // a new token is generated and this delayed reset is a no-op.
            let token = await coordinator.currentSessionToken

            // Wait 2 seconds so the user can see why the stream stopped.
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Bail out if this task was cancelled (e.g., startStream was called).
            guard !Task.isCancelled else { return }

            // Only reset if no new session has started since we stopped.
            let currentToken = await coordinator.currentSessionToken
            guard token == currentToken else { return }

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
