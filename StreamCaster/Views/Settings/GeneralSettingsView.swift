// GeneralSettingsView.swift
// StreamCaster
//
// Settings screen for general app configuration.
// Uses a standard SwiftUI Form with sections for:
//   • Camera: default camera selection
//   • Orientation: landscape / portrait lock
//   • Network: reconnect behavior
//   • Battery: low-battery warning threshold
//   • Recording: local recording toggle and destination
//   • About: app version and build info

import SwiftUI
import AVFoundation

/// A settings screen for camera, orientation, network, battery,
/// recording, and app-info preferences.
struct GeneralSettingsView: View {

    /// The shared SettingsViewModel that holds all settings state.
    @ObservedObject var viewModel: SettingsViewModel

    /// The list of reconnect-attempt options the user can choose from.
    /// Int.max represents "Unlimited" (never stop retrying).
    private let reconnectOptions: [Int] = [Int.max, 5, 10, 20, 50]

    var body: some View {
        Form {
            // ──────────────────────────────────────────────
            // MARK: - Camera Section
            // ──────────────────────────────────────────────
            Section {
                Picker("Default Camera", selection: $viewModel.selectedCameraDevice) {
                    ForEach(viewModel.availableCameraDevices) { device in
                        Text(device.localizedName)
                            .tag(device)
                    }
                }

                if !viewModel.availableStabilizationModes.isEmpty {
                    Picker("Video Stabilization", selection: $viewModel.videoStabilizationMode) {
                        ForEach(viewModel.availableStabilizationModes, id: \.rawValue) { mode in
                            Text(viewModel.stabilizationLabel(for: mode))
                                .tag(mode)
                        }
                    }
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("The camera that will be active when you start a new stream. Cinematic stabilization modes add noticeable preview latency.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Orientation Section
            // ──────────────────────────────────────────────
            Section {
                Picker("Preferred Orientation", selection: $viewModel.preferredOrientation) {
                    Text("Landscape").tag("landscape")
                    Text("Portrait").tag("portrait")
                }
            } header: {
                Text("Orientation")
            } footer: {
                Text("Orientation is locked once streaming begins. Choose the orientation you want before going live.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Network Section
            // ──────────────────────────────────────────────
            Section {
                Picker("Max Reconnect Attempts", selection: $viewModel.reconnectMaxAttempts) {
                    ForEach(reconnectOptions, id: \.self) { value in
                        Text(viewModel.reconnectLabel(for: value))
                            .tag(value)
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text("If the connection drops, the app will automatically try to reconnect up to this many times.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Battery Section
            // ──────────────────────────────────────────────
            Section {
                VStack(alignment: .leading) {
                    // Show the current threshold above the slider
                    Text("Warning at: \(viewModel.lowBatteryThreshold)%")

                    // Slider for battery threshold (1–20%)
                    Slider(
                        value: batteryThresholdBinding,
                        in: 1...20,
                        step: 1
                    )
                    // Min and max labels
                    HStack {
                        Text("1%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("20%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Battery")
            } footer: {
                Text("The app will warn you when battery drops below this level during a stream.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Power Saving Section
            // ──────────────────────────────────────────────
            Section {
                // Toggle that controls whether minimal mode is active
                // when the app first opens. Minimal mode hides the
                // camera preview to reduce GPU usage and save battery.
                Toggle(isOn: $viewModel.startInMinimalMode) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start in Minimal Mode")
                        Text("Hides camera preview to save battery during streaming")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Power Saving")
            }

            // ──────────────────────────────────────────────
            // MARK: - Recording Section
            // ──────────────────────────────────────────────
            Section {
                // Toggle to enable/disable local recording
                Toggle("Save Local Recording", isOn: $viewModel.isLocalRecordingEnabled)

                // Only show destination picker when recording is enabled
                if viewModel.isLocalRecordingEnabled {
                    Picker("Save To", selection: $viewModel.recordingDestination) {
                        Text("Photos Library").tag(RecordingDestination.photosLibrary)
                        Text("Documents Folder").tag(RecordingDestination.documents)
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("When enabled, a copy of your stream is saved on your device.")
            }

            // ──────────────────────────────────────────────
            // MARK: - About Section
            // ──────────────────────────────────────────────
            Section {
                // App version — read from the app bundle's Info.plist
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }

                // Build number
                HStack {
                    Text("Build")
                    Spacer()
                    Text(buildNumber)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("General")
    }

    // MARK: - Helpers

    /// Converts the Int threshold to a Double binding for the Slider.
    private var batteryThresholdBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(viewModel.lowBatteryThreshold) },
            set: { viewModel.lowBatteryThreshold = Int($0) }
        )
    }

    /// Reads the app version string from Info.plist (e.g., "1.0.0").
    /// Falls back to "—" if not found (happens in SwiftUI previews).
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Reads the build number from Info.plist (e.g., "42").
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
