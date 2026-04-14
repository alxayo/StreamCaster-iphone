import SwiftUI

// MARK: - StreamView
// StreamView is the main screen of the app.
//
// LAYOUT:
// +---------------------------------------------+
// | Camera Preview (full screen)                 |
// |                                              |
// | +-- HUD (top, full width) ----------------+ |
// | | 2500 kbps 30 fps | 05:23 | YouTube RTMP | |
// | +---------------------+-------------------+ |
// |                                              |
// |                               [Endpoint]     |
// |                               [START/STOP]   |
// |                               [Mute]         |
// |                               [Camera]       |
// |                               [Minimal]      |
// |                               [Settings]     |
// +---------------------------------------------+
//
// Controls are in a vertical column on the right edge,
// vertically centered. Buttons appear/disappear based
// on stream state.

struct StreamView: View {

    @StateObject private var viewModel = StreamViewModel()

    @State private var showSettings = false
    @State private var showStopConfirmation = false

    // MARK: - Body

    var body: some View {
        ZStack {

            // -- Layer 1: Camera preview (full screen) --
            if viewModel.isMinimalMode {
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
                CameraPreviewView()
                    .ignoresSafeArea()
            }

            // -- Layer 2: Gradient overlays --
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.6), Color.black.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)

                Spacer()
            }
            .ignoresSafeArea()

            // -- Layer 3: HUD + Control Panel --
            VStack(spacing: 0) {
                // HUD at top — only visible when streaming or reconnecting.
                if viewModel.isStreaming || viewModel.isReconnecting || viewModel.isConnecting {
                    StreamHudView(viewModel: viewModel)
                }

                if let errorMessage = viewModel.errorMessage {
                    errorBanner(message: errorMessage)
                        .padding(.top, 8)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 8)

            // -- Layer 4: Control panel (right edge, vertically centered) --
            HStack {
                Spacer()
                controlPanel
                    .padding(.trailing, 16)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.loadProfiles()
        }
        .onChange(of: showSettings) { isShowing in
            if !isShowing {
                // Reload profiles after settings sheet closes in case
                // the user added/edited/deleted endpoint profiles.
                viewModel.loadProfiles()
            }
        }
    }

    // MARK: - Error Banner

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

    // MARK: - Control Panel (Vertical Right-Edge Column)

    /// Vertical column of control buttons on the right edge of the screen.
    /// Buttons appear/disappear based on stream state per the visibility matrix.
    private var controlPanel: some View {
        VStack(spacing: 16) {

            // 1. Endpoint Switch
            if viewModel.showEndpointSwitch {
                EndpointSwitchButton(viewModel: viewModel)
            }

            // 2. Start/Stop (always visible)
            startStopButton

            // 3. Mute
            if viewModel.showMuteButton {
                muteButton
            }

            // 4. Camera Switch
            if viewModel.showCameraSwitch {
                cameraSwitchButton
            }

            // 5. Minimal Mode
            if viewModel.showMinimalMode {
                minimalModeButton
            }

            // 6. Settings
            if viewModel.showSettingsButton {
                settingsButton
            }
        }
    }

    // MARK: - Start / Stop Button

    private var startStopButton: some View {
        Button {
            let transport = viewModel.sessionSnapshot.transport
            switch transport {
            case .idle, .stopped:
                viewModel.startStream(profileId: viewModel.effectiveProfileId)
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
                    Image(systemName: "stop.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24))
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
    }

    /// Start/Stop button color per spec:
    /// Idle = blue accent, Previewing (idle+preview) = green, Streaming = red.
    private var startStopButtonColor: Color {
        if viewModel.isStreaming || viewModel.isReconnecting {
            return .red
        } else if viewModel.isConnecting {
            return .red
        } else if viewModel.isPreviewing {
            // Previewing state: green "Go live"
            return Color(red: 76 / 255, green: 175 / 255, blue: 80 / 255)
        } else {
            // Idle (no preview yet): blue accent
            return .blue
        }
    }

    /// Context menu for start/stop button (long press).
    @ViewBuilder
    private var streamContextMenu: some View {
        let transport = viewModel.sessionSnapshot.transport

        switch transport {
        case .idle, .stopped:
            Button {
                viewModel.startStream(profileId: viewModel.effectiveProfileId)
            } label: {
                Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
            }

            Button {
                viewModel.startStreamWithRecording(profileId: viewModel.effectiveProfileId)
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

    // MARK: - Small Control Buttons (40pt circle, black 60% bg)

    private var muteButton: some View {
        Button {
            viewModel.toggleMute()
        } label: {
            Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 20))
                .foregroundColor(viewModel.isMuted ? .red : .white)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.6))
                )
        }
        .frame(width: 44, height: 44)
    }

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
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.6))
                )
        } primaryAction: {
            viewModel.switchCamera()
        }
        .frame(width: 44, height: 44)
    }

    private var minimalModeButton: some View {
        Button {
            viewModel.toggleMinimalMode()
        } label: {
            Image(systemName: viewModel.isMinimalMode ? "moon.fill" : "moon")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(viewModel.isMinimalMode
                            ? Color.blue.opacity(0.6)
                            : Color.black.opacity(0.6))
                )
        }
        .frame(width: 44, height: 44)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.6))
                )
        }
        .frame(width: 44, height: 44)
        .sheet(isPresented: $showSettings) {
            SettingsRootView()
        }
    }
}

// MARK: - PulseModifier

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
