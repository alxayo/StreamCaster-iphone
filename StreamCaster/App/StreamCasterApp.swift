// StreamCasterApp.swift
// StreamCaster
//
// The main entry point of the StreamCaster app.
// SwiftUI uses the @main attribute to know where the app starts.

import SwiftUI
import AVFoundation

/// This is the starting point of the app.
/// The @main attribute tells Swift "run this first."
/// We use @UIApplicationDelegateAdaptor to connect our AppDelegate
/// so we can still use UIKit lifecycle events (like orientation control).
///
/// APP NAVIGATION STRUCTURE:
/// ┌─ StreamView (Main Screen) ─────────────────────┐
/// │  Camera preview + streaming controls             │
/// │  [Settings ⚙️] button → opens Settings          │
/// ├──────────────────────────────────────────────────┤
/// │                                                  │
/// │  Settings (Sheet)                                │
/// │  ├── Endpoint Setup (RTMP URL, keys, profiles)   │
/// │  ├── Video & Audio Settings                      │
/// │  └── General Settings                            │
/// └──────────────────────────────────────────────────┘
///
/// ON FIRST LAUNCH:
/// If Camera or Microphone permissions haven't been granted yet,
/// the app shows the PermissionRequestView instead of StreamView.
/// Once all required permissions are granted, the user sees StreamView.
@main
struct StreamCasterApp: App {

    // Connect the UIKit AppDelegate so we get lifecycle callbacks
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Security Curtain
    //
    // When the app goes to the App Switcher (e.g., the user swipes up
    // or double-taps the home button), iOS takes a screenshot of the
    // app to show in the switcher. This screenshot could reveal:
    //   - The camera preview (what you're streaming)
    //   - Stream keys or server URLs in settings
    //
    // To protect privacy, we overlay an opaque "curtain" view whenever
    // the scene phase becomes `.inactive` (which happens when entering
    // the App Switcher, receiving a phone call, etc.).
    //
    // `.active`   = app is in the foreground and interactive
    // `.inactive` = app is visible but not interactive (App Switcher, alerts)
    // `.background` = app is fully in the background

    /// Tracks whether the app is active, inactive, or in the background.
    /// SwiftUI updates this automatically.
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Termination Recovery State

    /// Controls whether the "session ended unexpectedly" alert is shown.
    @State private var showRecoveryAlert = false

    /// Stores the recovery result so we can reference it in the alert.
    @State private var recoveryResult: TerminationRecovery.RecoveryResult?

    // MARK: - Permission State

    /// Tracks whether the user has granted the required permissions
    /// (camera and microphone). We check this on every launch.
    @State private var hasRequiredPermissions = false

    /// Whether we've finished the initial permission check.
    /// Prevents a flash of the wrong screen on launch.
    @State private var hasCheckedPermissions = false

    var body: some Scene {
        // WindowGroup is the main window of the app.
        // Everything the user sees starts here.
        WindowGroup {
            ZStack {
                // ── Main Content ──
                // Show the permission screen until the user has granted
                // camera + microphone access. After that, show StreamView.
                if !hasCheckedPermissions {
                    // Brief blank screen while we check permission status.
                    // This avoids flashing the wrong screen on launch.
                    Color(uiColor: UIColor(named: "DarkSurface") ?? .black)
                        .ignoresSafeArea()
                } else if hasRequiredPermissions {
                    // All required permissions are granted — show the stream!
                    StreamView()
                } else {
                    // Permissions are missing — ask the user to grant them.
                    // When the required permissions (camera + mic) are granted,
                    // the callback re-checks and transitions to StreamView.
                    PermissionRequestView {
                        checkRequiredPermissions()
                    }
                }

                // ── Security Curtain ──
                // When the scene is inactive, cover everything with an
                // opaque view. This hides the camera preview and any
                // sensitive info from the App Switcher screenshot.
                if scenePhase == .inactive {
                    SecurityCurtainView()
                }
            }
            // ── Permission Check ──
            // On every launch, check if camera and microphone access
            // have been granted. These are the minimum permissions
            // needed for streaming.
            .onAppear {
                checkRequiredPermissions()
            }
            // ── Re-check When Returning From Settings ──
            // The user might grant permissions in the iOS Settings app.
            // When they return, we re-check so the UI updates immediately.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification
                )
            ) { _ in
                checkRequiredPermissions()
            }
            // ── Termination Recovery ──
            // On first launch, check if the previous session was killed
            // unexpectedly. If so, show an alert explaining what happened.
            .onAppear {
                let result = TerminationRecovery.performRecoveryCheck()
                if result.needsUserAttention {
                    recoveryResult = result
                    showRecoveryAlert = true
                }
            }
            .alert(
                "Previous Session Ended",
                isPresented: $showRecoveryAlert,
                presenting: recoveryResult
            ) { result in
                // If there are orphaned files, offer to clean them up.
                if !result.orphanedRecordings.isEmpty {
                    Button("Delete Recordings", role: .destructive) {
                        TerminationRecovery.deleteOrphanedRecordings(
                            result.orphanedRecordings
                        )
                    }
                    Button("Keep Files", role: .cancel) { }
                } else {
                    // No orphaned files — just an OK button.
                    Button("OK", role: .cancel) { }
                }
            } message: { result in
                if result.wasUnexpectedlyTerminated {
                    if result.orphanedRecordings.isEmpty {
                        Text("Your previous stream was interrupted because the app was closed by iOS. No recording files were affected.")
                    } else {
                        Text("Your previous stream was interrupted because the app was closed by iOS. Found \(result.orphanedRecordings.count) incomplete recording file(s). Would you like to delete them?")
                    }
                } else {
                    Text("Found \(result.orphanedRecordings.count) incomplete recording file(s) from a previous session. Would you like to delete them?")
                }
            }
        }
    }

    // MARK: - Permission Helpers

    /// Checks whether Camera and Microphone permissions have been granted.
    /// These two are required for streaming — without them, the app can't
    /// capture video or audio.
    private func checkRequiredPermissions() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        // Both camera AND microphone must be authorized.
        hasRequiredPermissions = (cameraStatus == .authorized && micStatus == .authorized)

        // Mark that we've completed the initial check.
        hasCheckedPermissions = true
    }
}

// MARK: - Security Curtain View

/// A full-screen opaque view that covers the app when it goes to the
/// App Switcher. Shows the app name on a solid background so nothing
/// sensitive is visible in the iOS screenshot.
///
/// This is a privacy feature — without it, anyone who sees your App
/// Switcher could see your camera preview or stream key.
private struct SecurityCurtainView: View {
    var body: some View {
        // Fill the entire screen with a solid color.
        ZStack {
            // Use the app's dark surface color for a polished look.
            // Falls back to plain black if the color isn't in the asset catalog.
            Color(uiColor: UIColor(named: "DarkSurface") ?? .black)
                .ignoresSafeArea()

            // Show the app name so the user knows which app this is
            // in the App Switcher.
            VStack(spacing: 12) {
                // App icon placeholder — uses SF Symbol as a stand-in.
                Image(systemName: "video.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.8))

                Text("StreamCaster")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        // Prevent any interaction with the curtain — taps should not
        // pass through to the UI underneath.
        .allowsHitTesting(false)
        // Animate the curtain appearing/disappearing for a smooth transition.
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }
}
