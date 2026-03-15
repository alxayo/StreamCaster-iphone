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

    /// Latest user-visible stream error shown in the UI.
    @Published private(set) var errorMessage: String?

    // MARK: - Dependencies

    /// Reference to the streaming engine — the single source of truth
    private let engine: StreamingEngine

    /// Stores all Combine subscriptions so they stay alive.
    /// When the ViewModel is deallocated, these are cancelled automatically.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// Create a StreamViewModel that observes the given engine.
    /// Defaults to the shared singleton.
    init(engine: StreamingEngine? = nil) {
        self.engine = engine ?? .shared
        setupBindings()
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

                // Check if we're reconnecting (pattern match the enum)
                if case .reconnecting = snapshot.transport {
                    self.isReconnecting = true
                } else {
                    self.isReconnecting = false
                }

                // Read the mute state from the media snapshot
                self.isMuted = snapshot.media.audioMuted

                // Generate human-readable status text and color
                self.statusText = self.buildStatusText(for: snapshot.transport)
                self.statusColor = self.buildStatusColor(for: snapshot.transport)

                // Determine which buttons should be enabled
                self.canStartStream = snapshot.transport == .idle
                self.canStopStream = snapshot.transport == .live
                    || snapshot.transport == .connecting
                    || self.isReconnecting

                if case .stopped(let reason) = snapshot.transport {
                    self.errorMessage = self.message(for: reason)
                } else if snapshot.transport == .live || snapshot.transport == .connecting {
                    self.errorMessage = nil
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

    /// Switch between front and back camera.
    func switchCamera() {
        engine.switchCamera()
    }

    /// Clear the currently visible error from the UI.
    func dismissError() {
        errorMessage = nil
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
        case .reconnecting(let attempt, _):
            // Show which retry attempt we're on so the user knows
            // the app is still trying.
            return "Reconnecting (attempt \(attempt))..."
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
