import SwiftUI

// MARK: - StreamView
// ──────────────────────────────────────────────────────────────────
// StreamView is the main screen of the app — where streaming happens!
//
// LAYOUT:
// ┌─────────────────────────────────────────────┐
// │  Camera Preview (full screen background)     │
// │                                              │
// │  ┌─ HUD (top) ─────────────────────────────┐ │
// │  │ ● LIVE  00:15:32  720p  2.5 Mbps  30fps │ │
// │  └──────────────────────────────────────────┘ │
// │                                              │
// │                                              │
// │                                              │
// │  ┌─ Controls (bottom) ──────────────────────┐ │
// │  │  [Mute]  [● START/STOP]  [Switch Camera] │ │
// │  └──────────────────────────────────────────┘ │
// └─────────────────────────────────────────────┘
//
// The camera preview fills the entire screen. Controls and HUD
// are overlaid on top with semi-transparent backgrounds.
//
// HOW IT WORKS:
// 1. CameraPreviewView renders live video behind everything.
// 2. Gradient overlays darken the top and bottom edges so white
//    text and icons remain readable over any scene.
// 3. StreamHudView shows stats at the top.
// 4. Control buttons sit at the bottom for easy thumb access.
// ──────────────────────────────────────────────────────────────────

struct StreamView: View {

    /// The view model that manages streaming state and actions.
    /// `@StateObject` means this view OWNS the view model — it creates
    /// it once and keeps it alive for the view's entire lifetime.
    @StateObject private var viewModel = StreamViewModel()

    /// Whether the settings sheet is currently shown.
    @State private var showSettings = false

    /// Whether the endpoint/RTMP URL setup sheet is currently shown.
    @State private var showEndpointSetup = false

    // MARK: - Body

    var body: some View {
        ZStack {

            // ── Layer 1: Camera preview (full screen) ──
            // When minimal mode is ON the preview is replaced with a
            // dark placeholder to save GPU / battery. The stream itself
            // keeps sending video — only the on-device display is off.
            if viewModel.isMinimalMode {
                // ── Minimal mode: dark background with status info ──
                // The camera preview is hidden to save battery/GPU power,
                // but the stream is still sending video to the server.
                Color.black
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("Minimal Mode")
                                .font(.headline)
                                .foregroundColor(.gray)
                            Text("Preview hidden to save battery")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    )
            } else {
                // The live camera feed fills the entire screen edge to edge.
                // `.ignoresSafeArea()` makes it extend behind the status bar
                // and home indicator for a fully immersive look.
                CameraPreviewView()
                    .ignoresSafeArea()
            }

            // ── Layer 2: Gradient overlays for readability ──
            // Dark gradients at the top and bottom make white text and
            // icons easy to read no matter what the camera is pointing at.
            VStack(spacing: 0) {
                // Top gradient: dark at the top, fading to clear
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.6),
                        Color.black.opacity(0.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)

                Spacer()

                // Bottom gradient: clear at the top, fading to dark
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 160)
            }
            .ignoresSafeArea()

            // ── Layer 3: HUD + Controls ──
            // The actual interactive UI sits on top of everything.
            VStack {
                // Top: HUD bar showing stats
                StreamHudView(viewModel: viewModel)

                if let errorMessage = viewModel.errorMessage {
                    errorBanner(message: errorMessage)
                        .padding(.top, 8)
                }

                Spacer()

                // Bottom: Control buttons (mute, start/stop, camera switch)
                controlBar
            }
            .padding()
        }
        // Keep the status bar light (white) since the background is dark
        .preferredColorScheme(.dark)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Control Bar

    /// The bottom row of control buttons.
    ///
    /// LAYOUT:
    /// [Settings]  [Mute]  [● START/STOP]  [Record]  [Switch Camera]
    ///
    /// The start/stop button is bigger and centered to make it
    /// the most prominent control.
    private var controlBar: some View {
        HStack(spacing: 24) {
            // Settings gear — opens the settings sheet
            settingsButton

            // Mute toggle — silences the microphone
            muteButton

            Spacer()

            // Big start/stop button — the main action
            startStopButton

            Spacer()

            // Record toggle — saves a local MP4 copy of the stream
            recordButton

            // Switch between front and back camera
            cameraSwitchButton

            // Toggle minimal mode (hides camera preview to save power)
            minimalModeButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.6))
        .cornerRadius(16)
    }

    // MARK: - Start / Stop Button

    /// A big circular button that starts or stops the stream.
    ///
    /// - When idle: shows a red record icon → tapping starts the stream
    /// - When streaming: shows a white stop icon → tapping stops the stream
    /// - When connecting: disabled and shows a spinner
    private var startStopButton: some View {
        Button {
            if viewModel.isStreaming || viewModel.isConnecting || viewModel.isReconnecting {
                // Stop the stream if it's currently live or connecting
                viewModel.stopStream()
            } else {
                // Start the stream (using a default profile ID for now)
                viewModel.startStream(profileId: "default")
            }
        } label: {
            ZStack {
                // Outer circle background
                Circle()
                    .fill(startStopButtonColor)
                    .frame(width: 64, height: 64)

                // Icon: record circle or stop icon
                if viewModel.isConnecting {
                    // Show a spinner while connecting
                    ProgressView()
                        .tint(.white)
                } else if viewModel.isStreaming || viewModel.isReconnecting {
                    // Show stop icon when streaming
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                } else {
                    // Show record icon when idle
                    Image(systemName: "record.circle")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
            }
        }
        // Disable the button while the stream is stopping
        .disabled(viewModel.sessionSnapshot.transport == .stopping)
    }

    /// Pick the right background color for the start/stop button.
    private var startStopButtonColor: Color {
        if viewModel.isStreaming {
            // Brand red (#E53935) when live
            return Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255)
        } else if viewModel.isConnecting || viewModel.isReconnecting {
            // Orange while connecting/reconnecting
            return .orange
        } else {
            // Brand red for the "ready to start" state
            return Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255)
        }
    }

    // MARK: - Mute Button

    /// Toggles the microphone on and off.
    /// The icon changes to show the current mute state.
    private var muteButton: some View {
        Button {
            viewModel.toggleMute()
        } label: {
            // Show a slashed mic when muted, normal mic when unmuted
            Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 20))
                .foregroundColor(viewModel.isMuted ? .red : .white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.15))
                )
        }
    }

    // MARK: - Record Button

    /// Toggles local MP4 recording on and off.
    ///
    /// - When NOT recording: shows a red circle icon (like a record button)
    /// - When recording: shows a stop icon with a red background
    ///
    /// Recording saves a copy of the stream to the device's Documents
    /// folder as an MP4 file. The same encoded frames being sent to the
    /// server are written to disk, so there's minimal extra CPU usage.
    private var recordButton: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.red)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(viewModel.isRecording
                            ? Color.red.opacity(0.3)
                            : Color.white.opacity(0.15))
                )
        }
        // Only allow recording while the stream is live.
        // Recording without streaming could be added later but is
        // out of scope for the initial implementation.
        .disabled(!viewModel.isStreaming)
        .opacity(viewModel.isStreaming ? 1.0 : 0.4)
    }

    // MARK: - Camera Switch Button

    /// Switches between the front and back camera.
    private var cameraSwitchButton: some View {
        Button {
            viewModel.switchCamera()
        } label: {
            Image(systemName: "camera.rotate.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.15))
                )
        }
        // Disable camera switching while connecting to avoid glitches
        .disabled(viewModel.isConnecting)
    }

    // MARK: - Minimal Mode Button

    /// Toggles minimal mode, which hides the camera preview to save
    /// battery and GPU resources. A filled moon icon means minimal mode
    /// is active; an outline moon means the preview is visible.
    private var minimalModeButton: some View {
        Button(action: {
            viewModel.toggleMinimalMode()
        }) {
            Image(systemName: viewModel.isMinimalMode ? "moon.fill" : "moon")
                .font(.title2)
                .foregroundColor(.white)
                .padding(12)
                .background(
                    Circle()
                        .fill(viewModel.isMinimalMode
                            ? Color.blue.opacity(0.6)
                            : Color.black.opacity(0.4))
                )
        }
    }

    // MARK: - Settings Button

    /// Opens the settings screen as a sheet.
    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.15))
                )
        }
        .sheet(isPresented: $showSettings) {
            // Present the settings hub as a modal sheet.
            // Users can navigate to Endpoint, Video/Audio, and General
            // settings from within this sheet.
            SettingsRootView()
        }
    }
}

// MARK: - SwiftUI Preview

#Preview("Stream View") {
    StreamView()
}
