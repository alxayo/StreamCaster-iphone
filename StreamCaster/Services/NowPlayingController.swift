// NowPlayingController.swift
// StreamCaster
//
// ──────────────────────────────────────────────────────────────────
// NowPlayingController manages the Lock Screen and Control Center controls.
// When the user is streaming, it shows:
//   - Stream title ("StreamCaster Live") and elapsed duration
//   - Play/Pause button → maps to MUTE/UNMUTE (not stop!)
//   - Stop button → maps to stop stream + cancel reconnects
//
// ┌──────────────────────────────────────┐
// │  Lock Screen / Control Center        │
// │                                      │
// │  StreamCaster Live                   │
// │  ▶ / ❚❚  (Play/Pause = mute toggle) │
// │  ■ (Stop = stop stream entirely)     │
// └──────────────────────────────────────┘
//
// IMPORTANT DESIGN DECISION:
// The pause button mutes audio instead of stopping the stream.
// This prevents accidental broadcast termination from:
//   - AirPod removal
//   - Bluetooth button press
//   - Siri "pause" commands
//   - CarPlay events
// ──────────────────────────────────────────────────────────────────

import Foundation
import MediaPlayer

final class NowPlayingController {

    // MARK: - Callbacks

    /// Called when the user taps play/pause — toggles mute on/off.
    private var onToggleMute: (() -> Void)?

    /// Called when the user taps stop — ends the stream entirely.
    private var onStopStream: (() -> Void)?

    // MARK: - Debounce

    /// Timer used to prevent rapid-fire play/pause events.
    /// Some Bluetooth devices send duplicate events; debouncing
    /// ensures we only act once per 500ms.
    private var debounceTimer: Timer?

    /// How long to wait (in seconds) before accepting another
    /// play/pause event. 500ms is a good balance between
    /// responsiveness and accidental-tap prevention.
    private let debounceInterval: TimeInterval = 0.5

    // MARK: - Configure

    /// Set up the Lock Screen / Control Center remote commands.
    ///
    /// Call this once when streaming begins. It registers handlers
    /// for play, pause, toggle-play-pause, and stop commands.
    ///
    /// - Parameters:
    ///   - onToggleMute: Closure to call when play/pause is pressed (mute toggle).
    ///   - onStopStream: Closure to call when stop is pressed (end stream).
    func configure(onToggleMute: @escaping () -> Void, onStopStream: @escaping () -> Void) {
        // Save the callbacks so our command handlers can use them.
        self.onToggleMute = onToggleMute
        self.onStopStream = onStopStream

        // Get the shared remote command center (Lock Screen + Control Center).
        let commandCenter = MPRemoteCommandCenter.shared()

        // --- Pause Command ---
        // When the user taps "pause," we MUTE audio (not stop the stream).
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onToggleMute?()
            return .success
        }

        // --- Play Command ---
        // When the user taps "play," we UNMUTE audio.
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.onToggleMute?()
            return .success
        }

        // --- Toggle Play/Pause Command ---
        // Some headphones and Bluetooth devices send this instead of
        // separate play/pause events. We debounce it to avoid double-fires.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.debouncedToggleMute()
            return .success
        }

        // --- Stop Command ---
        // This one actually stops the stream and cancels reconnect attempts.
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.onStopStream?()
            return .success
        }
    }

    // MARK: - Update Now Playing Info

    /// Update the Lock Screen / Control Center display with current stream info.
    ///
    /// Call this periodically (e.g., once per second) while streaming to keep
    /// the elapsed time up to date.
    ///
    /// - Parameters:
    ///   - snapshot: The current stream session state (transport, media, etc.).
    ///   - stats: Live statistics (bitrate, fps, duration, etc.).
    func updateNowPlaying(snapshot: StreamSessionSnapshot, stats: StreamStats) {
        // Build a dictionary of metadata that iOS displays on the Lock Screen.
        var nowPlayingInfo = [String: Any]()

        // --- Title ---
        // Show "StreamCaster Live" normally, or add "(Reconnecting...)"
        // if we lost the connection and are trying to get it back.
        switch snapshot.transport {
        case .reconnecting:
            nowPlayingInfo[MPMediaItemPropertyTitle] = "StreamCaster (Reconnecting...)"
        default:
            nowPlayingInfo[MPMediaItemPropertyTitle] = "StreamCaster Live"
        }

        // --- Elapsed Time ---
        // Convert milliseconds to seconds for the Lock Screen display.
        let elapsedSeconds = Double(stats.durationMs) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds

        // --- Playback Rate ---
        // 1.0 = "playing" (live). 0.0 = "paused" (not live).
        // This controls whether the Lock Screen shows a play or pause icon.
        let isLive = (snapshot.transport == .live)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isLive ? 1.0 : 0.0

        // --- Artist (subtitle) ---
        // Show "Live" as the artist/subtitle line for extra context.
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Live"

        // Push the updated info to the system.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Teardown

    /// Remove all command handlers and clear the Lock Screen display.
    ///
    /// Call this when streaming stops so the controls disappear from
    /// the Lock Screen and Control Center.
    func teardown() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove all targets so our closures don't fire anymore.
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)

        // Disable all commands so they don't show up.
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.playCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false

        // Clear the now playing info from the Lock Screen.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // Cancel any pending debounce timer.
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    // MARK: - Private Helpers

    /// Debounced version of toggleMute.
    ///
    /// Some Bluetooth devices send rapid duplicate events. This method
    /// ignores events that arrive within 500ms of the previous one,
    /// ensuring we only toggle once per user intent.
    private func debouncedToggleMute() {
        // If a debounce timer is already running, ignore this event —
        // it's a duplicate that arrived too quickly.
        guard debounceTimer == nil else { return }

        // Fire the mute toggle immediately.
        onToggleMute?()

        // Start a cooldown timer. During this 500ms window, any
        // additional toggle events will be ignored.
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            // Timer fired — clear it so the next event is accepted.
            self?.debounceTimer = nil
        }
    }
}
