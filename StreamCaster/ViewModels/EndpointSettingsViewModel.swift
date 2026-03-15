// EndpointSettingsViewModel.swift
// StreamCaster
//
// Manages the state for the Endpoint Settings screen.
// Handles loading, saving, editing, and deleting RTMP endpoint
// profiles. Also checks whether the user's configuration has a
// transport-security risk (plain rtmp:// with credentials).

import Foundation
import Combine

// MARK: - EndpointSettingsViewModel

/// ViewModel that powers the EndpointSettingsView.
///
/// It talks to the `EndpointProfileRepository` to persist profiles,
/// and exposes `@Published` properties so the SwiftUI view updates
/// automatically when data changes.
@MainActor
class EndpointSettingsViewModel: ObservableObject {

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Form Fields)
    // ──────────────────────────────────────────────────────────

    /// The RTMP server URL the user has typed in
    /// (e.g., "rtmp://ingest.example.com/live").
    @Published var rtmpUrl: String = "" {
        didSet { checkSecurityWarning() }
    }

    /// The secret stream key from the streaming platform.
    @Published var streamKey: String = ""

    /// Optional username for servers that require authentication.
    @Published var username: String = "" {
        didSet { checkSecurityWarning() }
    }

    /// Optional password for servers that require authentication.
    @Published var password: String = "" {
        didSet { checkSecurityWarning() }
    }

    /// A friendly name for this profile (e.g., "My Twitch Channel").
    @Published var profileName: String = ""

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Profile List)
    // ──────────────────────────────────────────────────────────

    /// All saved endpoint profiles loaded from the repository.
    @Published var profiles: [EndpointProfile] = []

    /// The ID of the profile currently being edited (nil = new profile).
    @Published var selectedProfileId: String?

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (Alerts & Warnings)
    // ──────────────────────────────────────────────────────────

    /// `true` when the user has entered credentials AND the URL
    /// uses plain `rtmp://` instead of the encrypted `rtmps://`.
    @Published var showSecurityWarning: Bool = false

    /// Human-readable error message shown if a save/delete fails.
    @Published var saveError: String?

    /// Placeholder for a future connection-test result (T-028).
    @Published var testConnectionResult: String?

    // ──────────────────────────────────────────────────────────
    // MARK: - Dependencies
    // ──────────────────────────────────────────────────────────

    /// The repository that reads/writes endpoint profiles.
    /// Uses the protocol so we can swap in a mock for testing.
    private let repository: EndpointProfileRepository

    // ──────────────────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────────────────

    /// Creates the view model with the given repository.
    /// Defaults to the shared DependencyContainer's repository
    /// so the view can just write `@StateObject private var viewModel = EndpointSettingsViewModel()`.
    init(repository: EndpointProfileRepository = DependencyContainer.shared.endpointProfileRepository) {
        self.repository = repository
        loadProfiles()
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Public Methods
    // ──────────────────────────────────────────────────────────

    /// Reload all profiles from persistent storage.
    func loadProfiles() {
        profiles = repository.getAll()
    }

    /// Save the current form fields as a profile.
    ///
    /// If `selectedProfileId` is set we update that profile;
    /// otherwise we create a brand-new one with a fresh UUID.
    func saveCurrentProfile() {
        // Clear any previous error so the UI doesn't show stale messages.
        saveError = nil

        // Use the existing ID if editing, or generate a new UUID.
        let id = selectedProfileId ?? UUID().uuidString

        // Build the profile from the current form fields.
        let profile = EndpointProfile(
            id: id,
            name: profileName.isEmpty ? "Untitled" : profileName,
            rtmpUrl: rtmpUrl,
            streamKey: streamKey,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            isDefault: profiles.first(where: { $0.id == id })?.isDefault ?? false
        )

        do {
            try repository.save(profile)

            // After saving, select this profile so the user sees it highlighted.
            selectedProfileId = id

            // Refresh the list to reflect the change.
            loadProfiles()
        } catch {
            saveError = "Failed to save profile: \(error.localizedDescription)"
        }
    }

    /// Delete a profile by its ID.
    /// - Parameter id: The unique ID of the profile to remove.
    func deleteProfile(id: String) {
        saveError = nil

        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        do {
            try repository.delete(profile)

            // If we just deleted the profile we were editing, clear the form.
            if selectedProfileId == id {
                newProfile()
            }

            loadProfiles()
        } catch {
            saveError = "Failed to delete profile: \(error.localizedDescription)"
        }
    }

    /// Mark a profile as the default (the one used on app launch).
    /// - Parameter id: The unique ID of the profile to make default.
    func setDefault(id: String) {
        saveError = nil

        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        do {
            try repository.setDefault(profile)
            loadProfiles()
        } catch {
            saveError = "Failed to set default: \(error.localizedDescription)"
        }
    }

    /// Load a saved profile's data into the form fields for editing.
    /// - Parameter profile: The profile to edit.
    func selectProfile(_ profile: EndpointProfile) {
        selectedProfileId = profile.id
        profileName = profile.name
        rtmpUrl = profile.rtmpUrl
        streamKey = profile.streamKey
        username = profile.username ?? ""
        password = profile.password ?? ""
    }

    /// Clear all form fields and deselect the current profile.
    /// Use this when the user wants to create a brand-new profile.
    func newProfile() {
        selectedProfileId = nil
        profileName = ""
        rtmpUrl = ""
        streamKey = ""
        username = ""
        password = ""
        saveError = nil
        testConnectionResult = nil
    }

    /// Placeholder for future connection testing (T-028).
    /// For now it just sets a message so the UI has something to show.
    func testConnection() {
        testConnectionResult = "Connection test not yet implemented (T-028)."
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Private Helpers
    // ──────────────────────────────────────────────────────────

    /// Show a security warning when the URL is plain rtmp://
    /// (not encrypted) AND the user has entered credentials.
    /// Credentials sent over unencrypted RTMP can be intercepted.
    private func checkSecurityWarning() {
        let hasCredentials = !username.isEmpty || !password.isEmpty
        let isPlainRtmp = rtmpUrl.lowercased().hasPrefix("rtmp://")

        showSecurityWarning = hasCredentials && isPlainRtmp
    }
}
