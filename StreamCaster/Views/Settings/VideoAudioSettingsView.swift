// VideoAudioSettingsView.swift
// StreamCaster
//
// Settings screen for video and audio configuration.
// Uses a standard SwiftUI Form with sections for:
//   • Video: resolution, FPS, bitrate, keyframe interval
//   • Audio: bitrate, sample rate, stereo/mono
//   • Adaptive Bitrate: enable/disable with explanation

import SwiftUI

/// A settings screen where the user configures video quality,
/// audio quality, and adaptive bitrate behavior.
struct VideoAudioSettingsView: View {

    /// The shared SettingsViewModel that holds all settings state.
    /// Changes here are automatically saved to UserDefaults.
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            // ──────────────────────────────────────────────
            // MARK: - Video Settings Section
            // ──────────────────────────────────────────────
            Section {
                // Resolution picker — shows only resolutions the camera supports
                Picker("Resolution", selection: $viewModel.selectedResolution) {
                    ForEach(viewModel.availableResolutions, id: \.self) { resolution in
                        Text(viewModel.resolutionLabel(for: resolution))
                            .tag(resolution)
                    }
                }

                // FPS picker — options update when resolution changes
                Picker("Frame Rate", selection: $viewModel.selectedFps) {
                    ForEach(viewModel.availableFrameRates, id: \.self) { fps in
                        Text("\(fps) fps")
                            .tag(fps)
                    }
                }

                // Video bitrate slider (500–8000 kbps)
                VStack(alignment: .leading) {
                    // Show the current value above the slider
                    Text("Video Bitrate: \(viewModel.videoBitrateKbps) kbps")

                    // Slider needs a Double binding, so we convert Int ↔ Double
                    Slider(
                        value: videoBitrateBinding,
                        in: 500...8000,
                        step: 100
                    )
                    // Show min and max labels below the slider
                    HStack {
                        Text("500")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("8000")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Keyframe interval picker (1–5 seconds)
                Picker("Keyframe Interval", selection: $viewModel.keyframeIntervalSec) {
                    ForEach(1...5, id: \.self) { seconds in
                        Text("\(seconds) sec")
                            .tag(seconds)
                    }
                }
            } header: {
                Text("Video Settings")
            } footer: {
                Text("Higher bitrate = better quality but needs more upload bandwidth.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Audio Settings Section
            // ──────────────────────────────────────────────
            Section {
                // Audio bitrate picker — common streaming values
                Picker("Audio Bitrate", selection: $viewModel.audioBitrateKbps) {
                    Text("64 kbps").tag(64)
                    Text("96 kbps").tag(96)
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                }

                // Sample rate picker
                Picker("Sample Rate", selection: $viewModel.audioSampleRate) {
                    Text("44,100 Hz").tag(44100)
                    Text("48,000 Hz").tag(48000)
                }

                // Stereo / Mono toggle
                Toggle("Stereo Audio", isOn: $viewModel.isStereo)
            } header: {
                Text("Audio Settings")
            } footer: {
                Text("Mono uses less bandwidth. Stereo sounds better for music streams.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Adaptive Bitrate Section
            // ──────────────────────────────────────────────
            Section {
                Toggle("Adaptive Bitrate (ABR)", isOn: $viewModel.isAbrEnabled)
            } header: {
                Text("Adaptive Bitrate")
            } footer: {
                Text("When enabled, the app automatically lowers video quality if your network slows down, and raises it when conditions improve. Recommended for mobile streaming.")
            }
        }
        .navigationTitle("Video & Audio")
    }

    // MARK: - Helpers

    /// Converts the Int bitrate to a Double binding for the Slider.
    /// Slider requires Binding<Double>, but we store bitrate as Int.
    private var videoBitrateBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(viewModel.videoBitrateKbps) },
            set: { viewModel.videoBitrateKbps = Int($0) }
        )
    }
}
