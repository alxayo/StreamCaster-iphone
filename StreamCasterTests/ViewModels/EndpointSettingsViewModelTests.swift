// EndpointSettingsViewModelTests.swift
// StreamCasterTests
//
// Unit tests for EndpointSettingsViewModel — manages the RTMP endpoint
// configuration form (URL, stream key, profile name, etc.).
//
// WHY THESE TESTS MATTER:
// The endpoint form is where users enter sensitive information like
// stream keys and passwords. If defaults are wrong (e.g., a URL
// is pre-filled when it shouldn't be) or the security warning
// doesn't trigger for plain rtmp://, users could accidentally
// send credentials in cleartext.
//
// TESTING STRATEGY:
// EndpointSettingsViewModel depends on EndpointProfileRepository.
// We create a simple mock that returns an empty profile list,
// so we can test the ViewModel's initial state and the security
// warning logic without needing real Keychain access.

import XCTest
@testable import StreamCaster

// MARK: - Mock EndpointProfileRepository
// ──────────────────────────────────────────────────────────────────
// A fake profile store that starts with no saved profiles.
// This lets us test the ViewModel's "new user" experience —
// all form fields should be empty and ready for input.
// ──────────────────────────────────────────────────────────────────

private class MockEndpointProfileRepository: EndpointProfileRepository {

    /// In-memory storage for profiles (starts empty).
    private var profiles: [EndpointProfile] = []

    /// Return all saved profiles (empty list for a new user).
    func getAll() -> [EndpointProfile] { profiles }

    /// Look up a profile by ID.
    func getById(_ id: String) -> EndpointProfile? {
        profiles.first { $0.id == id }
    }

    /// Return the default profile (none set for a new user).
    func getDefault() -> EndpointProfile? {
        profiles.first { $0.isDefault }
    }

    /// Save a profile to the in-memory store.
    func save(_ profile: EndpointProfile) throws {
        // Remove any existing profile with the same ID, then add the new one.
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
    }

    /// Delete a profile from the in-memory store.
    func delete(_ profile: EndpointProfile) throws {
        profiles.removeAll { $0.id == profile.id }
    }

    /// Mark a profile as the default (un-mark all others first).
    func setDefault(_ profile: EndpointProfile) throws {
        // Reset all profiles' default flag, then set the target.
        profiles = profiles.map { p in
            var updated = p
            updated.isDefault = (p.id == profile.id)
            return updated
        }
    }

    /// Always return true — our mock "Keychain" is always available.
    func isKeychainAvailable() -> Bool { true }
}

// MARK: - EndpointSettingsViewModelTests

/// Tests for EndpointSettingsViewModel's initial form state and security logic.
/// All tests run on @MainActor because the ViewModel is @MainActor.
@MainActor
final class EndpointSettingsViewModelTests: XCTestCase {

    // Fresh ViewModel + mock repository for each test.
    private var viewModel: EndpointSettingsViewModel!
    private var mockRepository: MockEndpointProfileRepository!

    override func setUp() {
        super.setUp()
        // Create a fresh mock repository (starts with zero profiles).
        mockRepository = MockEndpointProfileRepository()
        // Inject the mock so the ViewModel doesn't touch the real Keychain.
        viewModel = EndpointSettingsViewModel(repository: mockRepository)
    }

    override func tearDown() {
        viewModel = nil
        mockRepository = nil
        super.tearDown()
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Initial Form State Tests
    // ──────────────────────────────────────────────────────────
    // When a user opens the endpoint settings for the first time
    // (no saved profiles), all form fields should be blank.

    /// Verify all text fields start empty for a new profile.
    /// Users should see a clean form ready for their RTMP details.
    func testInitialFormFieldsAreEmpty() {
        // Profile name: blank — the user will type something like "My Twitch".
        XCTAssertEqual(viewModel.profileName, "",
                       "Profile name should be empty for a new profile")

        // RTMP URL: blank — the user will paste their ingest URL.
        XCTAssertEqual(viewModel.rtmpUrl, "",
                       "RTMP URL should be empty for a new profile")

        // Stream key: blank — the user will paste their secret key.
        XCTAssertEqual(viewModel.streamKey, "",
                       "Stream key should be empty for a new profile")

        // Username: blank — optional field, most servers don't need it.
        XCTAssertEqual(viewModel.username, "",
                       "Username should be empty for a new profile")

        // Password: blank — optional field, most servers don't need it.
        XCTAssertEqual(viewModel.password, "",
                       "Password should be empty for a new profile")
    }

    /// Verify no profile is selected when starting fresh.
    /// A nil selectedProfileId means we're creating a new profile,
    /// not editing an existing one.
    func testNoProfileSelectedInitially() {
        XCTAssertNil(viewModel.selectedProfileId,
                     "No profile should be selected when form is fresh")
    }

    /// Verify the profile list starts empty for a new user.
    func testProfileListStartsEmpty() {
        XCTAssertTrue(viewModel.profiles.isEmpty,
                      "Profile list should be empty when no profiles are saved")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Alert & Warning Initial State Tests
    // ──────────────────────────────────────────────────────────

    /// Verify the security warning is NOT shown initially.
    /// With an empty URL, there's no rtmp:// to warn about.
    func testSecurityWarningHiddenInitially() {
        XCTAssertFalse(viewModel.showSecurityWarning,
                       "Security warning should be hidden when URL is empty")
    }

    /// Verify there is no save error on startup.
    func testNoSaveErrorInitially() {
        XCTAssertNil(viewModel.saveError,
                     "Save error should be nil before any save attempt")
    }

    /// Verify there is no connection test result on startup.
    func testNoTestResultInitially() {
        XCTAssertNil(viewModel.testConnectionResult,
                     "Test connection result should be nil before any test")
        XCTAssertNil(viewModel.testResultIcon,
                     "Test result icon should be nil before any test")
    }

    /// Verify connection test is NOT in progress initially.
    func testNotTestingConnectionInitially() {
        XCTAssertFalse(viewModel.isTestingConnection,
                       "Should not be testing connection on startup")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Security Warning Logic Tests
    // ──────────────────────────────────────────────────────────
    // The security warning should appear when the URL uses
    // plain rtmp:// (unencrypted). This is important because
    // credentials sent over plain RTMP can be intercepted.

    /// Verify the security warning appears for plain rtmp:// URLs.
    /// Plain RTMP is unencrypted — credentials could be intercepted
    /// by anyone on the same network (e.g., public Wi-Fi).
    func testSecurityWarningShownForPlainRTMP() {
        // Simulate the user typing a plain rtmp:// URL.
        viewModel.rtmpUrl = "rtmp://live.example.com/app"

        // The warning should now be visible to alert the user.
        XCTAssertTrue(viewModel.showSecurityWarning,
                      "Security warning should show for plain rtmp:// URL")
    }

    /// Verify the security warning does NOT appear for rtmps:// URLs.
    /// rtmps:// uses TLS encryption, so credentials are safe in transit.
    func testSecurityWarningHiddenForRTMPS() {
        // Simulate the user typing a secure rtmps:// URL.
        viewModel.rtmpUrl = "rtmps://live.example.com/app"

        // No warning needed — the connection is encrypted.
        XCTAssertFalse(viewModel.showSecurityWarning,
                       "Security warning should NOT show for encrypted rtmps:// URL")
    }

    /// Verify the security warning handles case-insensitive URLs.
    /// Some users might type "RTMP://" in uppercase — the check
    /// should still catch it.
    func testSecurityWarningCaseInsensitive() {
        // Uppercase "RTMP://" should still trigger the warning.
        viewModel.rtmpUrl = "RTMP://live.example.com/app"

        XCTAssertTrue(viewModel.showSecurityWarning,
                      "Security warning should work regardless of URL casing")
    }

    /// Verify the security warning disappears when URL is cleared.
    /// If the user erases the URL field, the warning should go away.
    func testSecurityWarningDisappearsWhenUrlCleared() {
        // First, trigger the warning with a plain URL.
        viewModel.rtmpUrl = "rtmp://live.example.com/app"
        XCTAssertTrue(viewModel.showSecurityWarning,
                      "Precondition: warning should be shown")

        // Now clear the URL — warning should disappear.
        viewModel.rtmpUrl = ""
        XCTAssertFalse(viewModel.showSecurityWarning,
                       "Security warning should disappear when URL is cleared")
    }

    /// Verify the security warning disappears when switching to rtmps://.
    /// If the user corrects their URL to use encryption, the warning goes away.
    func testSecurityWarningDisappearsWhenSwitchedToRTMPS() {
        // Start with plain rtmp://.
        viewModel.rtmpUrl = "rtmp://live.example.com/app"
        XCTAssertTrue(viewModel.showSecurityWarning,
                      "Precondition: warning should be shown for rtmp://")

        // User corrects the URL to use rtmps://.
        viewModel.rtmpUrl = "rtmps://live.example.com/app"
        XCTAssertFalse(viewModel.showSecurityWarning,
                       "Security warning should disappear after switching to rtmps://")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - New Profile (Reset) Tests
    // ──────────────────────────────────────────────────────────

    /// Verify newProfile() clears all form fields.
    /// This is used when the user taps "New Profile" to start fresh.
    func testNewProfileClearsAllFields() {
        // First, fill in some data (simulating an edited profile).
        viewModel.profileName = "My Channel"
        viewModel.rtmpUrl = "rtmp://example.com/live"
        viewModel.streamKey = "secret-key-123"
        viewModel.username = "user"
        viewModel.password = "pass"
        viewModel.selectedProfileId = "some-id"

        // Now reset — this should clear everything.
        viewModel.newProfile()

        // All fields should be back to empty.
        XCTAssertEqual(viewModel.profileName, "",
                       "Profile name should be cleared after newProfile()")
        XCTAssertEqual(viewModel.rtmpUrl, "",
                       "RTMP URL should be cleared after newProfile()")
        XCTAssertEqual(viewModel.streamKey, "",
                       "Stream key should be cleared after newProfile()")
        XCTAssertEqual(viewModel.username, "",
                       "Username should be cleared after newProfile()")
        XCTAssertEqual(viewModel.password, "",
                       "Password should be cleared after newProfile()")
        XCTAssertNil(viewModel.selectedProfileId,
                     "Selected profile ID should be nil after newProfile()")

        // Error/test state should also be cleared.
        XCTAssertNil(viewModel.saveError,
                     "Save error should be cleared after newProfile()")
        XCTAssertNil(viewModel.testConnectionResult,
                     "Test result should be cleared after newProfile()")
        XCTAssertNil(viewModel.testResultIcon,
                     "Test result icon should be cleared after newProfile()")
        XCTAssertFalse(viewModel.isTestingConnection,
                       "Testing flag should be false after newProfile()")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Save & Load Profile Tests
    // ──────────────────────────────────────────────────────────

    /// Verify saving a profile adds it to the list.
    /// After calling saveCurrentProfile(), the profile should
    /// appear in the profiles array.
    func testSaveProfileAddsToList() {
        // Fill in the form fields.
        viewModel.profileName = "Test Channel"
        viewModel.rtmpUrl = "rtmps://ingest.example.com/live"
        viewModel.streamKey = "test-key-456"

        // Save the profile.
        viewModel.saveCurrentProfile()

        // The profile list should now contain exactly one profile.
        XCTAssertEqual(viewModel.profiles.count, 1,
                       "Should have 1 profile after saving")

        // Verify the saved data matches what we entered.
        let saved = viewModel.profiles.first
        XCTAssertEqual(saved?.name, "Test Channel",
                       "Saved profile name should match input")
        XCTAssertEqual(saved?.rtmpUrl, "rtmps://ingest.example.com/live",
                       "Saved RTMP URL should match input")
        XCTAssertEqual(saved?.streamKey, "test-key-456",
                       "Saved stream key should match input")
    }

    /// Verify that saving with an empty name defaults to "Untitled".
    /// This prevents profiles from having blank names in the list.
    func testSaveWithEmptyNameDefaultsToUntitled() {
        // Leave profileName empty but fill in the URL.
        viewModel.rtmpUrl = "rtmps://ingest.example.com/live"
        viewModel.streamKey = "key-789"

        viewModel.saveCurrentProfile()

        // The profile should be named "Untitled".
        XCTAssertEqual(viewModel.profiles.first?.name, "Untitled",
                       "Empty profile name should default to 'Untitled'")
    }

    /// Verify that selectProfile() loads a profile's data into the form.
    /// When the user taps a profile in the list, its data should fill
    /// the form fields so they can edit it.
    func testSelectProfileLoadsData() {
        // Create a profile to select.
        let profile = EndpointProfile(
            id: "test-id",
            name: "YouTube Stream",
            rtmpUrl: "rtmps://a.rtmp.youtube.com/live2",
            streamKey: "yt-key-abc",
            username: "ytuser",
            password: "ytpass"
        )

        // Load it into the form.
        viewModel.selectProfile(profile)

        // All form fields should now match the profile's data.
        XCTAssertEqual(viewModel.selectedProfileId, "test-id",
                       "Selected profile ID should match")
        XCTAssertEqual(viewModel.profileName, "YouTube Stream",
                       "Profile name should match selected profile")
        XCTAssertEqual(viewModel.rtmpUrl, "rtmps://a.rtmp.youtube.com/live2",
                       "RTMP URL should match selected profile")
        XCTAssertEqual(viewModel.streamKey, "yt-key-abc",
                       "Stream key should match selected profile")
        XCTAssertEqual(viewModel.username, "ytuser",
                       "Username should match selected profile")
        XCTAssertEqual(viewModel.password, "ytpass",
                       "Password should match selected profile")
    }
}
