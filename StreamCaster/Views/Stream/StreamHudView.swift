import SwiftUI

// MARK: - StreamHudView
// StreamHudView shows real-time streaming statistics at the top
// of the screen during Live and Reconnecting states.
//
// LAYOUT:
// +------------------------------------------------------------+
// | 2500 kbps  30 fps  1920x1080 | 05:23 | YouTube RTMPS REC  |
// |         LEFT                 | CENTER|   RIGHT (badges)    |
// +------------------------------------------------------------+

struct StreamHudView: View {

    @ObservedObject var viewModel: StreamViewModel

    var body: some View {
        HStack(spacing: 0) {

            // -- Left: Stats --
            HStack(spacing: 12) {
                Text("\(viewModel.streamStats.videoBitrateKbps) kbps")
                Text("\(Int(viewModel.streamStats.fps)) fps")
                Text(viewModel.streamStats.resolution)
            }

            Spacer()

            // -- Center: Duration --
            Text(compactDuration)
                .monospacedDigit()

            Spacer()

            // -- Right: Badges --
            HStack(spacing: 8) {
                if let name = viewModel.activeProfileName {
                    hudBadge(name, color: .white)
                }

                if let badge = viewModel.activeProtocolBadge {
                    hudBadge(badge, color: protocolBadgeColor(badge))
                }

                if let codec = viewModel.activeVideoCodec, codec != .h264 {
                    hudBadge(codec.rawValue.uppercased(), color: Color(red: 0.73, green: 0.53, blue: 0.99))
                }

                if viewModel.streamStats.isRecording {
                    hudBadge("REC", color: .red)
                }

                if viewModel.streamStats.thermalLevel == .fair {
                    hudBadge("MODERATE", color: .yellow)
                } else if viewModel.streamStats.thermalLevel == .serious {
                    hudBadge("SEVERE", color: Color(red: 1.0, green: 0.53, blue: 0.0))
                } else if viewModel.streamStats.thermalLevel == .critical {
                    hudBadge("CRITICAL", color: .red)
                }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5))
    }

    // MARK: - Helpers

    /// Duration formatted as MM:SS or H:MM:SS (hours only when >= 1 hour).
    private var compactDuration: String {
        let totalSeconds = Int(viewModel.streamStats.durationMs / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// A small colored badge pill used in the right section.
    private func hudBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.7))
            .cornerRadius(4)
    }

    /// Map protocol badge text to its badge color per spec.
    /// RTMPS = green, SRT = cyan, RTMP = white.
    private func protocolBadgeColor(_ badge: String) -> Color {
        switch badge {
        case "RTMPS":
            return .green
        case "SRT":
            return .cyan
        default:
            return .white
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
