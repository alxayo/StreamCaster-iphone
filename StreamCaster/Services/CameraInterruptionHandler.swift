// CameraInterruptionHandler.swift
// StreamCaster
//
// Detects when iOS takes the camera away from the app and handles
// the transition gracefully.
//
// WHEN DOES THIS HAPPEN?
// - User dismisses PiP while the app is in the background
// - Another app (FaceTime, Camera) takes the camera
// - Audio session interruption causes PiP to stop (causal chain)
// - System pressure forces camera shutdown
//
// WHAT DO WE DO?
// 1. If video+audio mode: Stop video track, continue audio-only streaming
// 2. If video-only mode: Stop streaming gracefully (nothing left to send)
// 3. When returning to foreground: Re-acquire camera, resume video
//
// This handler DOES NOT manage PiP itself (that's PiPManager's job).
// It reacts to the RESULT of camera loss, whatever the cause.
//
// Usage:
//   let handler = CameraInterruptionHandler()
//   handler.onCameraInterrupted = { origin in /* pause video, switch to audio-only */ }
//   handler.onCameraRestored = { /* re-enable video track */ }
//   handler.startObserving()

import Foundation
import AVFoundation
import Combine
import UIKit

// MARK: - CameraInterruptionHandler

/// Observes camera interruption notifications from AVCaptureSession
/// and UIApplication lifecycle events. Notifies the streaming engine
/// when the camera is lost or restored so it can switch between
/// video+audio and audio-only modes.
final class CameraInterruptionHandler {

    // MARK: - Callbacks

    /// Called when the camera is interrupted (taken away by iOS).
    /// The `InterruptionOrigin` describes *why* it happened, so the
    /// engine can show an appropriate message to the user.
    var onCameraInterrupted: ((InterruptionOrigin) -> Void)?

    /// Called when the camera becomes available again (e.g., the user
    /// returned to the foreground or the competing app released it).
    var onCameraRestored: (() -> Void)?

    // MARK: - Private State

    /// Keeps track of our NotificationCenter subscriptions so they are
    /// automatically removed when this object is deallocated.
    private var cancellables = Set<AnyCancellable>()

    /// Tracks whether the camera is currently interrupted.
    /// We use this to avoid sending duplicate "interrupted" or
    /// "restored" callbacks.
    private(set) var isCameraInterrupted: Bool = false

    /// Remembers what caused the current interruption so we can
    /// include it in log messages and analytics.
    private(set) var lastInterruptionOrigin: InterruptionOrigin = .none

    /// The capture session to observe for interruptions.
    /// This is set via `startObserving(captureSession:)`.
    /// We keep a weak reference to avoid retain cycles — the session
    /// is owned by the encoder bridge, not by us.
    private weak var captureSession: AVCaptureSession?

    // MARK: - Start / Stop

    /// Begin observing camera interruption notifications.
    /// Call this when the stream starts.
    ///
    /// - Parameter captureSession: The active AVCaptureSession. We observe
    ///   its interruption notifications. If `nil`, we still observe
    ///   foreground/background transitions but won't get session-level events.
    func startObserving(captureSession: AVCaptureSession? = nil) {
        self.captureSession = captureSession

        // Reset state for this observation session.
        isCameraInterrupted = false
        lastInterruptionOrigin = .none

        // ── 1. Camera was interrupted ──
        // iOS posts this when another app takes the camera, or when
        // system pressure forces the camera to shut down.
        NotificationCenter.default
            .publisher(for: .AVCaptureSessionWasInterrupted)
            .sink { [weak self] notification in
                self?.handleSessionInterrupted(notification)
            }
            .store(in: &cancellables)

        // ── 2. Camera interruption ended ──
        // iOS posts this when the camera becomes available again.
        // For example, the user closed FaceTime and our app can
        // reclaim the camera.
        NotificationCenter.default
            .publisher(for: .AVCaptureSessionInterruptionEnded)
            .sink { [weak self] _ in
                self?.handleInterruptionEnded()
            }
            .store(in: &cancellables)

        // ── 3. App returning to foreground ──
        // When the user taps our app icon after it was backgrounded,
        // we should try to re-acquire the camera. iOS may have taken
        // it away while we were in the background.
        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.handleWillEnterForeground()
            }
            .store(in: &cancellables)

        // ── 4. App moved to background ──
        // Track when we go to the background so we know the camera
        // might be interrupted soon (unless PiP keeps it alive).
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleDidEnterBackground()
            }
            .store(in: &cancellables)
    }

    /// Stop observing all notifications. Call this when the stream stops.
    func stopObserving() {
        cancellables.removeAll()
        captureSession = nil
    }

    // MARK: - Camera Re-acquisition

    /// Attempt to re-acquire the camera after returning to foreground.
    ///
    /// This method checks whether the capture session is still running.
    /// If it was interrupted, we try to start it again. If the camera
    /// hardware is available, iOS will grant it back to us.
    ///
    /// This is async because starting a capture session can take a
    /// moment (camera hardware initialization).
    func attemptCameraReacquisition() async {
        guard isCameraInterrupted else {
            // Camera was never interrupted — nothing to re-acquire.
            return
        }

        guard let session = captureSession else {
            // No capture session reference — can't re-acquire.
            // The engine will need to handle this at a higher level.
            return
        }

        // Check if the session is already running. If it is, the
        // interruption was already resolved by iOS automatically.
        if session.isRunning {
            handleInterruptionEnded()
            return
        }

        // Try to start the session again. We do this on a background
        // queue because AVCaptureSession.startRunning() is a blocking
        // call that can take a moment.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                continuation.resume()
            }
        }

        // After starting, check if the session is actually running.
        // If it is, the camera was successfully re-acquired.
        if session.isRunning {
            handleInterruptionEnded()
        }
    }

    // MARK: - Private Notification Handlers

    /// Handle the `AVCaptureSessionWasInterrupted` notification.
    ///
    /// iOS includes a "reason" in the notification's userInfo that
    /// tells us WHY the camera was interrupted. We map this to our
    /// `InterruptionOrigin` enum.
    private func handleSessionInterrupted(_ notification: Notification) {
        // Don't send duplicate "interrupted" callbacks.
        guard !isCameraInterrupted else { return }

        // Extract the interruption reason from the notification.
        let origin = extractInterruptionOrigin(from: notification)

        isCameraInterrupted = true
        lastInterruptionOrigin = origin

        // Notify the streaming engine so it can switch to audio-only
        // mode or stop the stream, depending on the current media mode.
        onCameraInterrupted?(origin)
    }

    /// Handle the `AVCaptureSessionInterruptionEnded` notification.
    ///
    /// This means the camera hardware is available again. The engine
    /// can re-enable the video track.
    private func handleInterruptionEnded() {
        // Don't send duplicate "restored" callbacks.
        guard isCameraInterrupted else { return }

        isCameraInterrupted = false
        lastInterruptionOrigin = .none

        // Notify the streaming engine so it can resume video capture.
        onCameraRestored?()
    }

    /// Handle the app returning to the foreground.
    ///
    /// If the camera was interrupted while we were in the background,
    /// this is our chance to re-acquire it. We schedule a re-acquisition
    /// attempt after a short delay to let iOS finish its transition.
    private func handleWillEnterForeground() {
        // Only attempt re-acquisition if the camera is currently
        // interrupted. If it's still working (e.g., PiP kept it alive),
        // there's nothing to do.
        guard isCameraInterrupted else { return }

        // Give iOS a moment to finish the foreground transition,
        // then try to get the camera back.
        Task {
            // Small delay to let the system settle after foregrounding.
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await attemptCameraReacquisition()
        }
    }

    /// Handle the app moving to the background.
    ///
    /// We don't need to do anything specific here right now, but
    /// this is a good place to log the transition for debugging.
    /// PiP will keep the camera alive if it's active; otherwise
    /// iOS will interrupt the camera session shortly after.
    private func handleDidEnterBackground() {
        // Currently a no-op. The actual interruption (if any) will
        // be handled by handleSessionInterrupted when iOS posts it.
        //
        // Future: We could start a timer here to detect if the camera
        // gets interrupted within a few seconds of backgrounding.
    }

    // MARK: - Private Helpers

    /// Extract the `InterruptionOrigin` from an AVCaptureSession
    /// interruption notification.
    ///
    /// iOS includes the reason in the notification's userInfo dictionary
    /// under the key `AVCaptureSessionInterruptionReasonKey`.
    private func extractInterruptionOrigin(from notification: Notification) -> InterruptionOrigin {
        // Try to get the reason from the notification's userInfo.
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            // If we can't extract a reason, report it as a generic
            // camera unavailable interruption.
            return .cameraUnavailable
        }

        // Map AVFoundation's interruption reason to our app's
        // InterruptionOrigin enum.
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            // The app went to the background and iOS took the camera.
            // This is the most common reason during backgrounding
            // without PiP.
            return .cameraUnavailable

        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            // Another foreground app (Slide Over, Split View) is
            // using the camera. Common on iPads.
            return .cameraUnavailable

        case .videoDeviceNotAvailableDueToSystemPressure:
            // iOS shut down the camera because the device is under
            // heavy load (thermal or memory pressure).
            return .systemPressure

        case .audioDeviceInUseByAnotherClient:
            // Another app took the audio device. This can cascade
            // to a video interruption if PiP was relying on the
            // audio session.
            return .audioSession

        @unknown default:
            // Future-proofing: treat unknown reasons as generic
            // camera unavailable.
            return .cameraUnavailable
        }
    }
}
