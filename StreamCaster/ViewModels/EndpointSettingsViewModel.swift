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

    /// The video codec selected for this endpoint profile.
    /// Defaults to H.264 for maximum compatibility.
    /// H.265 and AV1 offer better compression but require Enhanced RTMP
    /// server support. AV1 also needs an A17 Pro chip or later.
    @Published var videoCodec: VideoCodec = .h264

    // ──────────────────────────────────────────────────────────
    // MARK: - Published Properties (SRT Fields)
    // ──────────────────────────────────────────────────────────
    // These fields are only relevant when the URL starts with srt://.
    // They are ignored for RTMP/RTMPS connections.

    /// SRT connection mode — how the SRT socket connects to the server.
    /// Caller mode is the default and most common for mobile streaming:
    /// the phone initiates the connection to a remote SRT listener.
    @Published var srtMode: SRTMode = .caller

    /// SRT encryption passphrase (10-79 characters, or empty for no encryption).
    /// When set, the SRT connection uses AES encryption to protect the stream.
    @Published var srtPassphrase: String = ""

    /// AES encryption key length for SRT connections.
    /// Only meaningful when `srtPassphrase` is non-empty.
    /// Defaults to `.aes256` (256-bit — the current industry standard).
    @Published var srtKeyLength: SRTKeyLength = .aes256

    /// SRT latency in milliseconds — buffer for network jitter.
    /// Higher values = more resilience but more delay.
    /// Default 120ms is a good balance for most networks.
    @Published var srtLatencyMs: Int = 120

    /// SRT stream ID — used by some servers to route streams.
    /// Similar to RTMP's stream key concept but for SRT connections.
    @Published var srtStreamId: String = ""

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

    /// Confirmation message shown briefly after a successful save or update.
    @Published var saveSuccessMessage: String?

    /// The result message from the last connection test (nil = no test run yet).
    @Published var testConnectionResult: String?

    /// The icon to show next to the test result (e.g., ✅, ❌, ⏱).
    @Published var testResultIcon: String?

    /// `true` while a connection test is in progress (shows a spinner).
    @Published var isTestingConnection: Bool = false

    // ──────────────────────────────────────────────────────────
    // MARK: - Computed Properties
    // ──────────────────────────────────────────────────────────

    /// The detected protocol based on the current URL.
    /// Examines the URL scheme (rtmp://, rtmps://, srt://) to determine
    /// which protocol the user intends to use. Falls back to RTMP if
    /// the scheme is not recognized or the URL is empty.
    var detectedProtocol: StreamProtocol {
        StreamProtocol.detect(from: rtmpUrl) ?? .rtmp
    }

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
        // SRT fields are included so they persist alongside the endpoint config.
        // For RTMP URLs the SRT values are stored but ignored at connection time.
        let profile = EndpointProfile(
            id: id,
            name: profileName.isEmpty ? "Untitled" : profileName,
            rtmpUrl: rtmpUrl,
            streamKey: streamKey,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            isDefault: profiles.first(where: { $0.id == id })?.isDefault ?? false,
            videoCodec: videoCodec,
            srtMode: srtMode,
            srtPassphrase: srtPassphrase.isEmpty ? nil : srtPassphrase,
            srtKeyLength: srtKeyLength,
            srtLatencyMs: srtLatencyMs,
            srtStreamId: srtStreamId.isEmpty ? nil : srtStreamId
        )

        do {
            try repository.save(profile)

            // After saving, select this profile so the user sees it highlighted.
            selectedProfileId = id

            // Show a brief success message so the user knows the save worked.
            let isUpdate = profiles.contains(where: { $0.id == id })
            saveSuccessMessage = isUpdate ? "Profile updated ✓" : "Profile saved ✓"

            // Refresh the list to reflect the change.
            loadProfiles()

            // Auto-dismiss the success message after 3 seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.saveSuccessMessage != nil {
                    self?.saveSuccessMessage = nil
                }
            }
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
            saveSuccessMessage = "Profile deleted ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.saveSuccessMessage != nil {
                    self?.saveSuccessMessage = nil
                }
            }
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
            saveSuccessMessage = "Default profile set ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.saveSuccessMessage != nil {
                    self?.saveSuccessMessage = nil
                }
            }
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
        // Restore the video codec the user previously chose for this profile.
        videoCodec = profile.videoCodec

        // Restore SRT-specific fields from the saved profile.
        // These are only meaningful when the URL starts with srt://,
        // but we always load them so switching back to an SRT URL
        // doesn't lose the user's previous SRT settings.
        srtMode = profile.srtMode
        srtPassphrase = profile.srtPassphrase ?? ""
        srtKeyLength = profile.srtKeyLength
        srtLatencyMs = profile.srtLatencyMs
        srtStreamId = profile.srtStreamId ?? ""
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
        // Reset video codec to H.264 — the safest default for new profiles.
        videoCodec = .h264
        // Reset SRT fields to sensible defaults for a new profile.
        srtMode = .caller
        srtPassphrase = ""
        srtKeyLength = .aes256
        srtLatencyMs = 120
        srtStreamId = ""
        saveError = nil
        testConnectionResult = nil
        testResultIcon = nil
        isTestingConnection = false
    }

    /// Run a lightweight connection test against the current form values.
    ///
    /// This builds a temporary EndpointProfile from the form fields
    /// and passes it to `ConnectionTester.test(profile:)`. The result
    /// is shown in the UI with an appropriate icon.
    func testConnection() {
        // Don't start a second test while one is already running.
        guard !isTestingConnection else { return }

        // Clear previous results and show the loading spinner.
        testConnectionResult = nil
        testResultIcon = nil
        isTestingConnection = true

        // Build a temporary profile from the current form fields.
        // We don't need a real ID — this profile won't be saved.
        // Include SRT fields so the test can validate SRT connectivity.
        let profile = EndpointProfile(
            id: "test-\(UUID().uuidString)",
            name: "Connection Test",
            rtmpUrl: rtmpUrl,
            streamKey: streamKey,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            videoCodec: videoCodec,
            srtMode: srtMode,
            srtPassphrase: srtPassphrase.isEmpty ? nil : srtPassphrase,
            srtKeyLength: srtKeyLength,
            srtLatencyMs: srtLatencyMs,
            srtStreamId: srtStreamId.isEmpty ? nil : srtStreamId
        )

        // Run the test in a background Task so the UI stays responsive.
        Task {
            let result = await ConnectionTester.test(profile: profile)

            // Map the result to an icon and message for the UI.
            switch result {
            case .success(let message):
                testResultIcon = "✅"
                testConnectionResult = message

            case .timeout(let message):
                testResultIcon = "⏱"
                testConnectionResult = message

            case .authFailure(let message):
                testResultIcon = "❌"
                testConnectionResult = message

            case .tlsError(let message):
                testResultIcon = "❌"
                testConnectionResult = message

            case .securityBlocked(let message):
                testResultIcon = "🔒"
                testConnectionResult = message

            case .networkError(let message):
                testResultIcon = "❌"
                testConnectionResult = message
            }

            // Hide the loading spinner.
            isTestingConnection = false
        }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Private Helpers
    // ──────────────────────────────────────────────────────────

    /// Show a security warning when the URL is plain rtmp://
    /// (not encrypted). Plaintext RTMP can be intercepted.
    private func checkSecurityWarning() {
        let isPlainRtmp = rtmpUrl.lowercased().hasPrefix("rtmp://")

        showSecurityWarning = isPlainRtmp
    }
}
