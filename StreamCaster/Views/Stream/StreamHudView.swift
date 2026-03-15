import SwiftUI

// MARK: - StreamHudView
// ──────────────────────────────────────────────────────────────────
// StreamHudView shows real-time streaming statistics at the top
// of the screen while the user is streaming.
//
// LAYOUT (when streaming):
// ┌──────────────────────────────────────────────────────┐
// │ ● LIVE  00:15:32       720p  2.5 Mbps  30 fps  🌡️  │
// └──────────────────────────────────────────────────────┘
//
// The left side shows connection status and duration.
// The right side shows video quality stats.
// A thermal warning icon appears if the device is overheating.
// A recording indicator ("● REC") appears if local recording is on.
// ──────────────────────────────────────────────────────────────────

struct StreamHudView: View {

    /// The view model that provides all the streaming data.
    /// `@ObservedObject` means this view will re-render when
    /// the view model's @Published properties change.
    @ObservedObject var viewModel: StreamViewModel

    var body: some View {
        HStack(spacing: 12) {

            // ── Left side: Status badge + duration ──

            // Status badge shows "LIVE", "CONNECTING", etc.
            statusBadge

            // Stream duration in HH:MM:SS format.
            // `.monospacedDigit()` prevents the text from jiggling
            // as digits change — each digit takes the same width.
            Text(viewModel.formattedDuration)
                .monospacedDigit()

            Spacer()

            // ── Right side: Stats (only visible when streaming) ──

            if viewModel.isStreaming {
                // Current video resolution (e.g., "1280x720")
                Text(viewModel.streamStats.resolution)

                // Current bitrate (e.g., "2.5 Mbps")
                Text(viewModel.formattedBitrate)

                // Current frames per second (e.g., "30 fps")
                Text("\(Int(viewModel.streamStats.fps)) fps")
            }

            // ── Warning and recording indicators ──

            // Show a thermometer icon when the device is overheating.
            // The view model sets `showThermalWarning` when thermal
            // level is "serious" or "critical".
            if viewModel.showThermalWarning {
                Image(systemName: "thermometer.high")
                    .foregroundColor(.orange)
            }

            // Show a red dot + "REC" when local recording is active.
            if viewModel.streamStats.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("REC")
                }
            }
        }
        // Use a monospaced font so numbers line up neatly
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Frosted glass background so text is readable over the camera
        .background(.ultraThinMaterial.opacity(0.8))
        .cornerRadius(8)
    }

    // MARK: - Status Badge

    /// Shows the current connection status as a colored dot + label.
    ///
    /// Colors:
    /// - Green  = Live (streaming successfully)
    /// - Yellow = Connecting (handshake in progress)
    /// - Orange = Reconnecting (lost connection, retrying)
    /// - Gray   = Idle / other states
    private var statusBadge: some View {
        HStack(spacing: 6) {
            // Colored dot indicator
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)

            // Status text (e.g., "LIVE", "CONNECTING")
            Text(statusLabel)
                .fontWeight(.bold)
        }
    }

    /// Pick the right color for the status dot based on connection state.
    private var statusDotColor: Color {
        if viewModel.isStreaming {
            // Brand red (#E53935) when live — matches the app's primary color
            return Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255)
        } else if viewModel.isConnecting {
            return .yellow
        } else if viewModel.isReconnecting {
            return .orange
        } else {
            return .gray
        }
    }

    /// Pick the right label text for the status badge.
    private var statusLabel: String {
        if viewModel.isStreaming {
            return "LIVE"
        } else if viewModel.isConnecting {
            return "CONNECTING"
        } else if viewModel.isReconnecting {
            return "RECONNECTING"
        } else {
            return "OFFLINE"
        }
    }
}

// MARK: - SwiftUI Preview

#Preview("HUD - Live") {
    ZStack {
        Color.black.ignoresSafeArea()
        StreamHudView(viewModel: StreamViewModel())
            .padding()
    }
}
