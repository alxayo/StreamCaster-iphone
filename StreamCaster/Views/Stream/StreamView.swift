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

    /// Guards against accidental "Stop" taps when recording is active.
    @State private var showStopConfirmation = false

    /// Detects device orientation.
    /// - `.regular` in portrait → buttons need a two-row layout to fit.
    /// - `.compact` in landscape → single row has enough horizontal space.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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
                    .padding(.horizontal)

                if let errorMessage = viewModel.errorMessage {
                    errorBanner(message: errorMessage)
                        .padding(.top, 8)
                        .padding(.horizontal)
                }

                Spacer()

                // Bottom: Control buttons (mute, start/stop, camera switch)
                controlBar
            }
            .padding(.vertical)
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

    /// The bottom row(s) of control buttons.
    ///
    /// PORTRAIT (two rows — buttons would overflow in a single row):
    /// ┌──────────────────────────────────────────────────┐
    /// │  [Settings] [Mute] [Record] [Camera] [Minimal]   │
    /// │              [●●● START/STOP ●●●]                │
    /// └──────────────────────────────────────────────────┘
    ///
    /// LANDSCAPE (single row — plenty of horizontal space):
    /// ┌──────────────────────────────────────────────────────────────┐
    /// │ [Settings] [Mute]   [● START/STOP]   [Record] [Camera] [M] │
    /// └──────────────────────────────────────────────────────────────┘
    private var controlBar: some View {
        Group {
            if verticalSizeClass == .regular {
                // ── Portrait: two-row layout ──
                // Secondary buttons on top, big start/stop below.
                VStack(spacing: 12) {
                    HStack {
                        settingsButton
                        Spacer(minLength: 0)
                        muteButton
                        Spacer(minLength: 0)
                        cameraSwitchButton
                        Spacer(minLength: 0)
                        minimalModeButton
                    }

                    startStopButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial.opacity(0.6))
                .cornerRadius(16)
                .padding(.horizontal, 12)
            } else {
                // ── Landscape: single-row layout ──
                // All buttons in one row with flexible spacing between each.
                HStack {
                    settingsButton
                    Spacer(minLength: 0)
                    muteButton
                    Spacer(minLength: 0)
                    startStopButton
                    Spacer(minLength: 0)
                    cameraSwitchButton
                    Spacer(minLength: 0)
                    minimalModeButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial.opacity(0.6))
                .cornerRadius(16)
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Start / Stop Button

    /// A big circular button that starts or stops the stream.
    ///
    /// - Tap when idle → start streaming
    /// - Tap when live → stop streaming (confirmation if recording)
    /// - Long-press → context menu with recording options
    private var startStopButton: some View {
        Button {
            let transport = viewModel.sessionSnapshot.transport
            switch transport {
            case .idle, .stopped:
                viewModel.startStream(profileId: "default")
            case .live, .connecting, .reconnecting:
                if viewModel.isRecording {
                    showStopConfirmation = true
                } else {
                    viewModel.stopStream()
                }
            case .stopping:
                break
            }
        } label: {
            ZStack {
                // Pulsing ring — only when truly live.
                if viewModel.isStreaming {
                    Circle()
                        .stroke(Color.red.opacity(0.4), lineWidth: 2)
                        .frame(width: 76, height: 76)
                        .modifier(PulseModifier())
                }

                Circle()
                    .fill(startStopButtonColor)
                    .frame(width: 64, height: 64)

                if viewModel.isConnecting {
                    ProgressView()
                        .tint(.white)
                } else if viewModel.isStreaming || viewModel.isReconnecting {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "record.circle")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(viewModel.sessionSnapshot.transport == .stopping)
        .contextMenu { streamContextMenu }
        .confirmationDialog(
            "Stop Stream",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Stream & Recording", role: .destructive) {
                viewModel.stopStream()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recording is in progress. Stopping the stream will also stop recording.")
        }
        .accessibilityLabel(viewModel.isStreaming ? "Stop stream" : "Start stream")
        .accessibilityHint("Long press for recording options")
    }

    /// Context menu items derived from the current transport and recording state.
    @ViewBuilder
    private var streamContextMenu: some View {
        let transport = viewModel.sessionSnapshot.transport

        switch transport {
        case .idle, .stopped:
            Button {
                viewModel.startStream(profileId: "default")
            } label: {
                Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
            }

            Button {
                viewModel.startStreamWithRecording(profileId: "default")
            } label: {
                Label("Go Live + Record", systemImage: "record.circle")
            }

        case .live:
            if viewModel.isRecording {
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle")
                }
            } else {
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
            }

            Button(role: .destructive) {
                viewModel.stopStream()
            } label: {
                Label("Stop Stream", systemImage: "xmark.circle")
            }

        case .connecting:
            Button(role: .destructive) {
                viewModel.stopStream()
            } label: {
                Label("Cancel Connection", systemImage: "xmark.circle")
            }

        case .reconnecting:
            Button(role: .destructive) {
                viewModel.stopStream()
            } label: {
                Label("Stop Stream", systemImage: "xmark.circle")
            }

        case .stopping:
            EmptyView()
        }
    }

    /// Pick the right background color for the start/stop button.
    private var startStopButtonColor: Color {
        if viewModel.isStreaming {
            return Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255)
        } else if viewModel.isConnecting || viewModel.isReconnecting {
            return .orange
        } else {
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

    // MARK: - Camera Switch Button

    /// Tap to cycle cameras; long-press for a menu of all available cameras.
    private var cameraSwitchButton: some View {
        Menu {
            ForEach(viewModel.availableCameraDevices) { device in
                Button {
                    viewModel.switchToCamera(device)
                } label: {
                    if device == viewModel.currentCameraDevice {
                        Label(device.localizedName, systemImage: "checkmark")
                    } else {
                        Text(device.localizedName)
                    }
                }
            }
        } label: {
            Image(systemName: "camera.rotate.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.15))
                )
        } primaryAction: {
            viewModel.switchCamera()
        }
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
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(viewModel.isMinimalMode
                            ? Color.blue.opacity(0.6)
                            : Color.white.opacity(0.15))
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

// MARK: - PulseModifier

/// Animates a repeating scale pulse from 1.0 → 1.2 and back.
/// Used on the stream button's outer ring to indicate a live broadcast.
private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .opacity(isPulsing ? 0.0 : 1.0)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - SwiftUI Preview

#Preview("Stream View") {
    StreamView()
}
