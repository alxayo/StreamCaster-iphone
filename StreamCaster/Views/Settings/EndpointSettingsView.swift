// EndpointSettingsView.swift
// StreamCaster
//
// Settings screen for configuring RTMP streaming endpoints.
// Users can enter a server URL, stream key, and optional
// credentials, then save multiple profiles for quick switching.
//
// Features:
//   • RTMP/RTMPS URL + stream key fields
//   • Optional username/password authentication
//   • Transport security warning for plain rtmp:// with credentials
//   • Save, edit, and delete endpoint profiles
//   • Set a default profile (auto-selected on launch)
//   • Test Connection placeholder (wired in T-028)

import SwiftUI

// MARK: - EndpointSettingsView

/// The Endpoint Settings screen where users configure their RTMP
/// server connection details and manage saved profiles.
struct EndpointSettingsView: View {

    /// The view model that manages form state and profile persistence.
    @StateObject private var viewModel = EndpointSettingsViewModel()

    var body: some View {
        Form {
            // ──────────────────────────────────────────────
            // MARK: - Saved Profiles List (top for visibility)
            // ──────────────────────────────────────────────
            if !viewModel.profiles.isEmpty {
                Section {
                    ForEach(viewModel.profiles) { profile in
                        // Each row: tap to load, shows star if default
                        Button {
                            viewModel.selectProfile(profile)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    // Profile name in bold
                                    Text(profile.name)
                                        .font(.body)
                                        .foregroundColor(.primary)

                                    // Show the RTMP URL below in smaller text
                                    Text(profile.rtmpUrl)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                // Star icon marks the default profile
                                if profile.isDefault {
                                    Image(systemName: "star.fill")
                                        .foregroundColor(.yellow)
                                        .accessibilityLabel("Default profile")
                                }

                                // Highlight the currently-selected profile
                                if viewModel.selectedProfileId == profile.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    // Swipe-to-delete on each profile row
                    .onDelete { indexSet in
                        for index in indexSet {
                            viewModel.deleteProfile(id: viewModel.profiles[index].id)
                        }
                    }
                } header: {
                    Text("Saved Profiles")
                } footer: {
                    Text("Tap a profile to edit it. Swipe left to delete.")
                }

                // ──────────────────────────────────────────
                // MARK: - Profile Actions
                // ──────────────────────────────────────────
                if let selectedId = viewModel.selectedProfileId {
                    Section {
                        // Set the selected profile as the default
                        Button {
                            viewModel.setDefault(id: selectedId)
                        } label: {
                            Label("Set as Default", systemImage: "star")
                        }

                        // Delete the selected profile
                        Button(role: .destructive) {
                            viewModel.deleteProfile(id: selectedId)
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                        }
                    } header: {
                        Text("Profile Actions")
                    }
                }
            }

            // ──────────────────────────────────────────────
            // MARK: - Endpoint Details Section
            // ──────────────────────────────────────────────
            Section {
                // Profile name — a friendly label like "My Twitch Channel"
                TextField("Profile Name", text: $viewModel.profileName)
                    .autocorrectionDisabled()

                // Server URL (e.g., "rtmp://ingest.example.com/live" or "srt://server:port")
                TextField("rtmp://server/app or srt://server:port", text: $viewModel.rtmpUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                // Show detected protocol badge below URL field.
                // Helps the user confirm which protocol will be used
                // based on the URL scheme they've entered.
                if !viewModel.rtmpUrl.isEmpty {
                    HStack {
                        Image(systemName: viewModel.detectedProtocol == .srt
                              ? "bolt.shield"
                              : "antenna.radiowaves.left.and.right")
                        Text(viewModel.detectedProtocol.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Stream key — treated as a secret, shown as dots
                SecureField("Stream Key", text: $viewModel.streamKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Endpoint Details")
            } footer: {
                Text("Enter the server URL and stream key provided by your streaming platform.")
            }

            // ──────────────────────────────────────────────
            // MARK: - SRT Configuration (shown only for srt:// URLs)
            // ──────────────────────────────────────────────
            // This section appears dynamically when the user enters an srt:// URL.
            // It provides SRT-specific options that don't apply to RTMP connections.
            if viewModel.detectedProtocol == .srt {
                Section {
                    // SRT Mode picker — determines how the SRT socket connects.
                    // Most users want "Caller" (the phone calls out to a server).
                    Picker("Connection Mode", selection: $viewModel.srtMode) {
                        ForEach(SRTMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                                Text(mode.subtitle)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .tag(mode)
                        }
                    }

                    // Passphrase field — enables AES encryption on the SRT connection.
                    // Must be 10-79 characters if set; leave empty for no encryption.
                    SecureField("Passphrase (optional)", text: $viewModel.srtPassphrase)

                    // Latency stepper — controls the SRT receive buffer size.
                    // Higher values absorb more network jitter but add delay.
                    // Range: 20ms (aggressive) to 8000ms (very lossy networks).
                    Stepper("Latency: \(viewModel.srtLatencyMs)ms",
                            value: $viewModel.srtLatencyMs,
                            in: 20...8000,
                            step: 10)

                    // Stream ID — some SRT servers use this to route incoming streams
                    // to the correct channel or application (similar to RTMP stream key).
                    TextField("Stream ID (optional)", text: $viewModel.srtStreamId)
                } header: {
                    Text("SRT Configuration")
                } footer: {
                    Text("SRT is optimized for low-latency streaming over unreliable networks. Caller mode is recommended for most use cases.")
                }
            }

            // ──────────────────────────────────────────────
            // MARK: - Authentication Section (Optional)
            // ──────────────────────────────────────────────
            Section {
                // Username — some RTMP servers require login credentials
                TextField("Username (optional)", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                // Password — shown as dots, stored in the Keychain
                SecureField("Password (optional)", text: $viewModel.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentication")
            } footer: {
                Text("Only fill these in if your RTMP server requires a username and password.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Video Codec Section
            // ──────────────────────────────────────────────
            // Lets the user pick which video codec to use for this endpoint.
            // Each codec has a display name, subtitle, and optional badges
            // that warn about compatibility requirements.
            Section {
                // Picker bound to the viewModel's videoCodec property.
                // When the user picks a different codec, the form updates
                // immediately thanks to SwiftUI's two-way binding.
                Picker(selection: $viewModel.videoCodec) {
                    // Loop through every codec case (H.264, H.265, AV1).
                    ForEach(VideoCodec.allCases, id: \.self) { codec in
                        HStack {
                            // Left side: codec name and a short description
                            VStack(alignment: .leading, spacing: 2) {
                                Text(codec.displayName)
                                Text(codec.subtitle)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Badge: "Enhanced RTMP" — shown for codecs that
                            // need server-side Enhanced RTMP support (H.265, AV1).
                            if codec.requiresEnhancedRTMP {
                                Text("Enhanced RTMP")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(4)
                            }

                            // Badge: "Not Available" — shown when the device
                            // lacks hardware encoding for this codec (e.g., AV1
                            // on devices without an A17 Pro chip).
                            if !codec.isHardwareEncodingAvailable {
                                Text("Not Available")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.2))
                                    .foregroundColor(.red)
                                    .cornerRadius(4)
                            }
                        }
                        // Tag each row so the Picker knows which codec it represents.
                        .tag(codec)
                        // Dim and disable codecs that aren't available on this device.
                        // This prevents the user from selecting an unsupported codec.
                        .disabled(!codec.isHardwareEncodingAvailable)
                        .opacity(codec.isHardwareEncodingAvailable ? 1.0 : 0.5)
                    }
                } label: {
                    Text("Video Codec")
                }
            } header: {
                Text("Video Codec")
            } footer: {
                // Show a context-sensitive footer:
                // - Warning if the selected codec needs Enhanced RTMP
                // - Generic recommendation otherwise
                if viewModel.videoCodec.requiresEnhancedRTMP {
                    Text("⚠️ \(viewModel.videoCodec.displayName) requires Enhanced RTMP server support. Not all streaming platforms support this codec.")
                } else {
                    Text("H.264 is recommended for maximum compatibility with all streaming platforms.")
                }
            }

            // ──────────────────────────────────────────────
            // MARK: - Transport Security Warning
            // ──────────────────────────────────────────────
            if viewModel.showSecurityWarning {
                Section {
                    Label {
                        Text("This stream will use plaintext RTMP. Use rtmps:// when available.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                    }
                    .foregroundColor(.orange)
                } header: {
                    Text("Security Warning")
                }
            }

            // ──────────────────────────────────────────────
            // MARK: - Save / New Profile Buttons
            // ──────────────────────────────────────────────
            Section {
                // Save or update the current profile
                Button {
                    viewModel.saveCurrentProfile()
                } label: {
                    Label(
                        viewModel.selectedProfileId != nil ? "Update Profile" : "Save Profile",
                        systemImage: "square.and.arrow.down"
                    )
                }
                // Disable save if the URL field is empty
                .disabled(viewModel.rtmpUrl.trimmingCharacters(in: .whitespaces).isEmpty)

                // "New Profile" clears the form so the user can start fresh
                if viewModel.selectedProfileId != nil {
                    Button {
                        viewModel.newProfile()
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                }

                // Inline success feedback — visible right where the user tapped Save.
                if let successMessage = viewModel.saveSuccessMessage {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(successMessage)
                            .foregroundColor(.green)
                            .fontWeight(.medium)
                    }
                    .listRowBackground(Color.green.opacity(0.1))
                }

                // Inline error feedback — visible right where the user tapped Save.
                if let error = viewModel.saveError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                    }
                    .listRowBackground(Color.red.opacity(0.1))
                }
            }

            // ──────────────────────────────────────────────
            // MARK: - Test Connection
            // ──────────────────────────────────────────────
            Section {
                Button {
                    viewModel.testConnection()
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")

                        // Show a spinner while the test is running
                        if viewModel.isTestingConnection {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                // Disable if there's no URL to test, or a test is already running
                .disabled(
                    viewModel.rtmpUrl.trimmingCharacters(in: .whitespaces).isEmpty
                    || viewModel.isTestingConnection
                )

                // Show test result with an icon when available
                if let icon = viewModel.testResultIcon,
                   let message = viewModel.testConnectionResult {
                    HStack(alignment: .top, spacing: 8) {
                        Text(icon)
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Tests transport connectivity only — does not verify stream key or publish ability.")
            }
        }
        .navigationTitle("Endpoint")
        // Reload profiles whenever this view appears (e.g., coming back
        // from another screen that might have changed data).
        .onAppear {
            viewModel.loadProfiles()
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        EndpointSettingsView()
    }
}
