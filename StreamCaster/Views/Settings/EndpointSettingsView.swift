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
            // MARK: - Endpoint Details Section
            // ──────────────────────────────────────────────
            Section {
                // Profile name — a friendly label like "My Twitch Channel"
                TextField("Profile Name", text: $viewModel.profileName)
                    .autocorrectionDisabled()

                // RTMP server URL (e.g., "rtmp://ingest.example.com/live")
                TextField("rtmp://ingest.example.com/live", text: $viewModel.rtmpUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                // Stream key — treated as a secret, shown as dots
                SecureField("Stream Key", text: $viewModel.streamKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Endpoint Details")
            } footer: {
                Text("Enter the RTMP URL and stream key provided by your streaming platform.")
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
            }

            // Show save errors if any
            if let error = viewModel.saveError {
                Section {
                    Text(error)
                        .foregroundColor(.red)
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

            // ──────────────────────────────────────────────
            // MARK: - Saved Profiles List
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
