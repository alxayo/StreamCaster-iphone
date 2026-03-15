// SettingsRootView.swift
// StreamCaster
//
// The main settings hub screen. From here, users can navigate to:
//   • Endpoint — RTMP server URL, stream key, authentication
//   • Video & Audio — resolution, bitrate, frame rate, audio
//   • General — camera, orientation, battery, recording, about

import SwiftUI

/// SettingsRootView is the main settings screen.
/// It acts as a menu that links to all sub-settings screens.
///
/// NAVIGATION STRUCTURE:
/// ┌── SettingsRootView ─────────────────────────┐
/// │  Streaming                                   │
/// │    └── Endpoint → EndpointSettingsView        │
/// │  Quality                                     │
/// │    └── Video & Audio → VideoAudioSettingsView │
/// │  App                                         │
/// │    └── General → GeneralSettingsView          │
/// └──────────────────────────────────────────────┘
struct SettingsRootView: View {

    // MARK: - Environment

    /// Used to dismiss this view when presented as a sheet.
    /// Works on iOS 15+ (we avoid the newer `dismiss` API).
    @Environment(\.presentationMode) var presentationMode

    // MARK: - View Model

    /// The shared view model for Video/Audio and General settings.
    /// `@StateObject` means this view OWNS it — it stays alive as
    /// long as the settings sheet is open.
    @StateObject private var settingsViewModel = SettingsViewModel(
        settingsRepo: DependencyContainer.shared.settingsRepository,
        capabilityQuery: DependencyContainer.shared.deviceCapabilityQuery
    )

    // MARK: - Body

    var body: some View {
        // We wrap in NavigationView so NavigationLinks inside
        // the list can push sub-settings screens onto the stack.
        NavigationView {
            List {
                // ── Streaming section ──
                // Configure where the stream goes (RTMP server details).
                Section("Streaming") {
                    NavigationLink(destination: EndpointSettingsView()) {
                        Label("Endpoint", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                // ── Quality section ──
                // Configure how the stream looks and sounds.
                Section("Quality") {
                    NavigationLink(
                        destination: VideoAudioSettingsView(viewModel: settingsViewModel)
                    ) {
                        Label("Video & Audio", systemImage: "video.fill")
                    }
                }

                // ── App section ──
                // General preferences like camera, battery, recording.
                Section("App") {
                    NavigationLink(
                        destination: GeneralSettingsView(viewModel: settingsViewModel)
                    ) {
                        Label("General", systemImage: "gearshape.fill")
                    }
                }
            }
            .navigationTitle("Settings")
            // A "Done" button to dismiss the settings sheet.
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Settings Root") {
    SettingsRootView()
}
