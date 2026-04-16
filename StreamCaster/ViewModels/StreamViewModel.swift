import Foundation
import Combine
import AVFoundation

// MARK: - StreamViewModel
// ──────────────────────────────────────────────────────────────────
// StreamViewModel is the bridge between the StreamingEngine and SwiftUI views.
//
// It observes the engine's @Published properties and projects them into
// simple, UI-friendly values that SwiftUI views can easily display.
//
// For example, instead of checking `snapshot.transport` for the exact state,
// the view can just check `isStreaming` or `statusText`.
//
// ARCHITECTURE NOTE:
// - The ViewModel NEVER modifies engine state directly
// - It calls engine methods (startStream, stopStream, etc.)
// - It reads state from engine's @Published properties
// - All Combine subscriptions are stored in `cancellables` and cancelled in deinit
// ──────────────────────────────────────────────────────────────────

@MainActor
final class StreamViewModel: ObservableObject {

    // MARK: - Published Properties for UI

    /// The full session snapshot (for views that need detailed state)
    @Published private(set) var sessionSnapshot: StreamSessionSnapshot = .idle

    /// Live stream statistics (bitrate, fps, duration, etc.)
    @Published private(set) var streamStats: StreamStats = StreamStats()

    // ── Convenience properties for simpler UI binding ──

    /// `true` when the stream is live and sending data
    @Published private(set) var isStreaming: Bool = false

    /// `true` when trying to connect to the RTMP server
    @Published private(set) var isConnecting: Bool = false

    /// `true` when the connection was lost and the engine is retrying
    @Published private(set) var isReconnecting: Bool = false

    // ── Reconnection progress properties ──
    // Exposed as individual published properties so SwiftUI views can
    // bind directly without destructuring `TransportState`.

    /// Which retry attempt the engine is on right now (1, 2, 3 …).
    /// Only meaningful when `isReconnecting` is `true`.
    @Published private(set) var reconnectAttempt: Int = 0

    /// Total number of retry attempts configured by the user.
    /// `Int.max` means unlimited. Only meaningful when `isReconnecting`.
    @Published private(set) var reconnectMaxAttempts: Int = 0

    /// Seconds remaining until the next retry attempt.
    /// Decremented once per second by an internal timer.
    @Published private(set) var reconnectCountdownSeconds: Int = 0

    /// `true` when the microphone is muted
    @Published private(set) var isMuted: Bool = false

    /// Human-readable status like "Ready", "Live", "Connecting..."
    @Published private(set) var statusText: String = "Ready"

    /// Color name for the status indicator (used by SwiftUI views)
    @Published private(set) var statusColor: String = "gray"

    /// Stream duration formatted as "HH:MM:SS"
    @Published private(set) var formattedDuration: String = "00:00:00"

    /// Current bitrate formatted as "X.X Mbps" or "X kbps"
    @Published private(set) var formattedBitrate: String = "0 kbps"

    /// `true` when the user can tap "Start" (idle state)
    @Published private(set) var canStartStream: Bool = true

    /// `true` when the user can tap "Stop" (streaming or connecting)
    @Published private(set) var canStopStream: Bool = false

    /// `true` when the device is overheating (serious or critical)
    @Published private(set) var showThermalWarning: Bool = false

    /// `true` when local MP4 recording is active.
    /// The record button uses this to show the correct icon/color.
    @Published private(set) var isRecording: Bool = false

    /// Latest user-visible stream error shown in the UI.
    @Published private(set) var errorMessage: String?

    /// When `true`, the camera preview is hidden to save battery and reduce
    /// GPU usage. The stream continues normally — only the preview display
    /// is turned off. This is like closing your eyes while the camera records.
    ///
    /// Useful for long streams or when the phone is stationary (e.g., on a tripod).
    @Published var isMinimalMode: Bool = false

    /// `true` when the camera preview is attached and showing a live feed.
    @Published private(set) var isPreviewing: Bool = false

    // ── Endpoint profile properties for the endpoint picker ──

    /// All configured endpoint profiles (for the endpoint switch menu).
    @Published private(set) var endpointProfiles: [EndpointProfile] = []

    /// The ID of the currently selected (default) endpoint profile.
    @Published private(set) var selectedProfileId: String?

    /// Name of the endpoint currently being streamed to (set at stream start).
    @Published private(set) var activeProfileName: String?

    /// Protocol of the active stream (RTMP/RTMPS/SRT), set at stream start.
    @Published private(set) var activeProtocol: StreamProtocol?

    /// Video codec of the active stream, set at stream start.
    @Published private(set) var activeVideoCodec: VideoCodec?

    /// Protocol badge text distinguishing "RTMP" from "RTMPS", set at stream start.
    @Published private(set) var activeProtocolBadge: String?

    /// When `true`, recording will start automatically once the stream
    /// transitions to `.live`. Set by "Go Live + Record" in the context menu.
    /// Cleared once recording actually starts (or if the stream fails).
    private var pendingRecordOnStart: Bool = false

    // MARK: - Dependencies

    /// Reference to the streaming engine — the single source of truth
    private let engine: StreamingEngine

    /// Stores all Combine subscriptions so they stay alive.
    /// When the ViewModel is deallocated, these are cancelled automatically.
    private var cancellables = Set<AnyCancellable>()

    /// Timer that fires once per second to decrement `reconnectCountdownSeconds`.
    /// Created when entering reconnecting state, invalidated when leaving.
    private var countdownTimer: Timer?

    // MARK: - Init

    /// Create a StreamViewModel that observes the given engine.
    /// Defaults to the shared singleton.
    init(engine: StreamingEngine? = nil) {
        self.engine = engine ?? .shared
        setupBindings()
        loadProfiles()
    }

    // MARK: - Setup

    /// Subscribe to the engine's published properties and map them
    /// to our simple UI-friendly properties.
    private func setupBindings() {
        // ── Observe session snapshot changes ──
        // Every time the engine publishes a new snapshot, we update
        // all our convenience booleans and strings.
        engine.$sessionSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.sessionSnapshot = snapshot

                // Map transport state to simple booleans
                self.isStreaming = snapshot.transport == .live
                self.isConnecting = snapshot.transport == .connecting

                // Check if we're reconnecting and extract metadata
                if case .reconnecting(let attempt, let maxAttempts, let nextRetryMs) = snapshot.transport {
                    self.isReconnecting = true
                    self.reconnectAttempt = attempt
                    self.reconnectMaxAttempts = maxAttempts
                    // Convert milliseconds to whole seconds for the countdown.
                    // Each new .reconnecting event resets the countdown.
                    self.reconnectCountdownSeconds = max(0, Int(nextRetryMs / 1000))
                    self.startCountdownTimer()
                } else {
                    // Not reconnecting — clear metadata and stop timer.
                    if self.isReconnecting {
                        self.stopCountdownTimer()
                        self.reconnectAttempt = 0
                        self.reconnectMaxAttempts = 0
                        self.reconnectCountdownSeconds = 0
                    }
                    self.isReconnecting = false
                }

                // Read the mute state from the media snapshot
                self.isMuted = snapshot.media.audioMuted

                // Map recording state to a simple boolean for the UI.
                // We consider "starting" and "recording" both as "active"
                // so the button shows the stop icon immediately.
                if case .recording = snapshot.recording {
                    self.isRecording = true
                } else if case .starting = snapshot.recording {
                    self.isRecording = true
                } else {
                    self.isRecording = false
                }

                // Generate human-readable status text and color
                self.statusText = self.buildStatusText(for: snapshot.transport)
                self.statusColor = self.buildStatusColor(for: snapshot.transport)

                // Determine which buttons should be enabled
                switch snapshot.transport {
                case .idle, .stopped:
                    self.canStartStream = true
                default:
                    self.canStartStream = false
                }
                self.canStopStream = snapshot.transport == .live
                    || snapshot.transport == .connecting
                    || self.isReconnecting

                if case .stopped(let reason) = snapshot.transport {
                    self.errorMessage = self.message(for: reason)
                    self.pendingRecordOnStart = false
                } else if snapshot.transport == .live || snapshot.transport == .connecting {
                    self.errorMessage = nil
                }

                // Auto-start recording when the stream goes live and the
                // user chose "Go Live + Record" from the context menu.
                if snapshot.transport == .live && self.pendingRecordOnStart {
                    self.pendingRecordOnStart = false
                    Task { await self.engine.startRecording() }
                }
            }
            .store(in: &cancellables)

        // ── Observe stream stats changes ──
        // Stats update roughly once per second while streaming.
        // We format the raw numbers into display-ready strings.
        engine.$streamStats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                guard let self else { return }
                self.streamStats = stats

                // Format duration (milliseconds → "HH:MM:SS")
                self.formattedDuration = self.formatDuration(ms: stats.durationMs)

                // Format bitrate (kbps → "X.X Mbps" or "X kbps")
                self.formattedBitrate = self.formatBitrate(kbps: stats.videoBitrateKbps)

                // Show thermal warning if device is overheating
                self.showThermalWarning =
                    stats.thermalLevel == .serious || stats.thermalLevel == .critical
            }
            .store(in: &cancellables)

        // Prefer explicit engine-provided errors when available.
        engine.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                if let message, !message.isEmpty {
                    self.errorMessage = message
                }
            }
            .store(in: &cancellables)

        // Observe whether the camera preview is attached.
        engine.$isPreviewing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isPreviewing = value
            }
            .store(in: &cancellables)

        // Observe active profile metadata (set when stream starts).
        engine.$activeProfileName
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeProfileName)

        engine.$activeProtocol
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeProtocol)

        engine.$activeVideoCodec
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeVideoCodec)

        engine.$activeProtocolBadge
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeProtocolBadge)
    }

    // MARK: - Reconnection Countdown Timer

    /// Start a 1-second repeating timer that decrements
    /// `reconnectCountdownSeconds`. Each tick reduces the displayed
    /// "Next retry in Xs" value by one. The timer is cosmetic — the
    /// actual retry is scheduled by `ConnectionManager`. A new
    /// `.reconnecting` event from the engine resets the countdown.
    private func startCountdownTimer() {
        // Avoid duplicate timers if called rapidly.
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.reconnectCountdownSeconds > 0 {
                    self.reconnectCountdownSeconds -= 1
                }
            }
        }
    }

    /// Stop and discard the countdown timer.
    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    // MARK: - Actions
    // These methods delegate to the engine. The ViewModel never
    // modifies state directly — it only asks the engine to do things.

    /// Start streaming to the RTMP server for the given profile ID.
    func startStream(profileId: String) {
        Task {
            try await engine.startStream(profileId: profileId)
        }
    }

    /// Start streaming and automatically begin local recording once live.
    func startStreamWithRecording(profileId: String) {
        pendingRecordOnStart = true
        startStream(profileId: profileId)
    }

    /// Stop the current stream.
    func stopStream() {
        Task {
            await engine.stopStream(reason: .userRequest)
        }
    }

    /// Toggle microphone mute on/off.
    func toggleMute() {
        engine.toggleMute()
    }

    /// Toggle local MP4 recording on/off.
    ///
    /// When starting:
    ///   1. Checks that enough disk space is available.
    ///   2. Tells the engine to start recording.
    ///   3. The engine generates a filename and begins writing frames.
    ///
    /// When stopping:
    ///   1. Tells the engine to finalize the MP4 file.
    ///   2. The recording state transitions back to `.off`.
    func toggleRecording() {
        Task {
            if isRecording {
                // Currently recording → stop and finalize the file.
                await engine.stopRecording()
            } else {
                // Not recording → start a new recording.
                await engine.startRecording()
            }
        }
    }

    /// Cycle to the next camera (alternating front/back pattern).
    func switchCamera() {
        engine.switchCamera()
    }

    /// Switch to a specific camera device (from long-press menu).
    func switchToCamera(_ device: CameraDevice) {
        engine.switchToCamera(device)
    }

    /// All camera devices available on this hardware.
    var availableCameraDevices: [CameraDevice] {
        engine.availableCameraDevices
    }

    /// The camera currently in use.
    var currentCameraDevice: CameraDevice? {
        engine.currentCameraDevice
    }

    /// Clear the currently visible error from the UI.
    func dismissError() {
        errorMessage = nil
    }

    /// Toggle minimal mode on or off.
    ///
    /// In minimal mode:
    /// - Camera preview is hidden (saves GPU power)
    /// - All streaming controls remain visible and functional
    /// - The stream itself is NOT affected — it keeps sending data
    ///
    /// This is a UI-only change. The encoder bridge keeps running normally.
    func toggleMinimalMode() {
        isMinimalMode.toggle()
    }

    // MARK: - Endpoint Profile Management

    /// Load all endpoint profiles from the repository.
    func loadProfiles() {
        endpointProfiles = engine.getEndpointProfiles()
        if let defaultProfile = engine.getDefaultProfile() {
            selectedProfileId = defaultProfile.id
        } else {
            selectedProfileId = endpointProfiles.first?.id
        }
    }

    /// Set a profile as the default and reload the list.
    func selectEndpoint(profileId: String) {
        engine.setDefaultProfile(profileId)
        selectedProfileId = profileId
    }

    /// The profile ID to use when starting a stream.
    /// Falls back to "default" for legacy behavior.
    var effectiveProfileId: String {
        selectedProfileId ?? "default"
    }

    /// Name of the currently selected profile (for display under the endpoint button).
    var selectedProfileName: String? {
        endpointProfiles.first { $0.id == selectedProfileId }?.name
    }

    // MARK: - Button Visibility

    /// Whether the endpoint switch button should be visible.
    var showEndpointSwitch: Bool {
        guard !endpointProfiles.isEmpty else { return false }
        switch sessionSnapshot.transport {
        case .idle, .stopped: return true
        default: return false
        }
    }

    /// Whether the mute button should be visible.
    var showMuteButton: Bool {
        switch sessionSnapshot.transport {
        case .connecting, .live, .reconnecting: return true
        default: return false
        }
    }

    /// Whether the camera switch button should be visible.
    var showCameraSwitch: Bool {
        switch sessionSnapshot.transport {
        case .idle:
            return isPreviewing
        case .connecting, .live, .reconnecting:
            return true
        default:
            return false
        }
    }

    /// Whether the minimal mode button should be visible.
    var showMinimalMode: Bool {
        switch sessionSnapshot.transport {
        case .connecting, .live, .reconnecting: return true
        default: return false
        }
    }

    /// Whether the settings button should be visible.
    var showSettingsButton: Bool {
        switch sessionSnapshot.transport {
        case .idle, .stopped: return true
        default: return false
        }
    }

    // MARK: - Formatting Helpers

    /// Convert milliseconds to a "HH:MM:SS" string.
    ///
    /// Example: 3_661_000 ms → "01:01:01"
    private func formatDuration(ms: Int64) -> String {
        // Convert milliseconds to total seconds
        let totalSeconds = Int(ms / 1000)

        // Break into hours, minutes, seconds using integer division
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        // Format with leading zeros (e.g., "01:05:09")
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Format a bitrate value into a human-readable string.
    ///
    /// - Values >= 1000 kbps are shown as Mbps (e.g., "2.5 Mbps")
    /// - Values < 1000 kbps are shown as kbps (e.g., "500 kbps")
    private func formatBitrate(kbps: Int) -> String {
        if kbps >= 1000 {
            // Convert to Mbps with one decimal place
            let mbps = Double(kbps) / 1000.0
            return String(format: "%.1f Mbps", mbps)
        } else {
            return "\(kbps) kbps"
        }
    }

    /// Map a TransportState to a human-readable status string.
    ///
    /// These strings are displayed directly in the UI, so they
    /// should be short and easy to understand.
    private func buildStatusText(for transport: TransportState) -> String {
        switch transport {
        case .idle:
            return "Ready"
        case .connecting:
            return "Connecting..."
        case .live:
            return "Live"
        case .reconnecting(let attempt, let maxAttempts, _):
            // Show progress like "Reconnecting (3 of 10)..." when max is
            // finite, or "Reconnecting (attempt 3)..." when unlimited.
            if maxAttempts < Int.max {
                return "Reconnecting (\(attempt) of \(maxAttempts))..."
            } else {
                return "Reconnecting (attempt \(attempt))..."
            }
        case .stopping:
            return "Stopping..."
        case .stopped:
            return "Stopped"
        }
    }

    /// Map a TransportState to a color name for the status indicator.
    ///
    /// SwiftUI views can use this string with `Color(statusColor)` or
    /// map it to custom colors in their asset catalog.
    private func buildStatusColor(for transport: TransportState) -> String {
        switch transport {
        case .idle:
            return "gray"
        case .connecting:
            return "yellow"
        case .live:
            return "green"
        case .reconnecting:
            return "orange"
        case .stopping:
            return "yellow"
        case .stopped:
            return "red"
        }
    }

    private func message(for reason: StopReason) -> String? {
        switch reason {
        case .userRequest:
            return nil
        case .errorAuth:
            return "Failed to start stream. Check endpoint configuration and credentials."
        case .errorNetwork:
            return "Could not connect to the streaming endpoint."
        case .errorEncoder:
            return "Video encoder failed to start."
        case .errorCamera:
            return "Camera is unavailable."
        case .errorAudio:
            return "Microphone is unavailable."
        case .errorStorage:
            return "Recording stopped due to low storage."
        case .thermalCritical:
            return "Streaming stopped because the device overheated."
        case .batteryCritical:
            return "Streaming stopped due to critical battery level."
        case .pipDismissedVideoOnly:
            return "Streaming stopped when Picture in Picture was dismissed."
        case .osTerminated:
            return "Streaming stopped because the app was terminated by iOS."
        case .unknown:
            return "Streaming stopped due to an unknown error."
        }
    }
}
