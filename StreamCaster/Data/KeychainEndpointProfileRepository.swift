import Foundation

// MARK: - KeychainEndpointProfileRepository
/// Implements `EndpointProfileRepository` using a **hybrid storage strategy**:
///
///   • **UserDefaults** stores the list of profiles with non-sensitive fields
///     (id, name, URL, isDefault). This makes browsing and listing fast.
///
///   • **Keychain** stores sensitive credentials (stream key, username,
///     password) keyed by profile ID. This keeps secrets encrypted.
///
/// When loading a profile, we "hydrate" it — read the skeleton from
/// UserDefaults, then fill in the credentials from the Keychain.
///
/// Why not store everything in Keychain?
///   - The Keychain isn't designed for browsing/listing structured data.
///   - UserDefaults is fast for metadata but stores data in plaintext.
///   - The hybrid approach gives us the best of both worlds.
final class KeychainEndpointProfileRepository: EndpointProfileRepository {

    // MARK: - Constants

    /// The UserDefaults key where we store the JSON array of profile metadata.
    private let profilesKey = "com.port80.app.endpoint_profiles"

    /// UserDefaults key that tracks whether we've already created the
    /// default seed profile. We check this flag on every launch so we
    /// only seed once — even if the user later deletes the profile.
    private let seedProfileKey = "com.port80.app.seed_profile_created"

    /// UserDefaults instance. Using `.standard` — the default shared store.
    private let defaults: UserDefaults

    // MARK: - Init

    /// Creates a new repository.
    /// - Parameter defaults: The UserDefaults store to use. Defaults to `.standard`.
    ///   Pass a custom one in tests to avoid polluting real user data.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // On first launch, create a default "Local RTMP" profile so the
        // user has something ready to go out of the box — matching what
        // the Android app does.
        seedDefaultProfileIfNeeded()
    }

    // MARK: - EndpointProfileRepository Protocol

    /// Load ALL profiles from UserDefaults and fill in their credentials
    /// from the Keychain.
    func getAll() -> [EndpointProfile] {
        // Step 1: Load the raw metadata from UserDefaults.
        let skeletons = loadProfileSkeletons()

        // Step 2: Hydrate each one with Keychain credentials.
        return skeletons.map { hydrateProfile($0) }
    }

    /// Find a single profile by its ID.
    /// - Parameter id: The profile's unique identifier string.
    /// - Returns: The fully-hydrated profile, or `nil` if not found.
    func getById(_ id: String) -> EndpointProfile? {
        let skeletons = loadProfileSkeletons()

        // Look for a skeleton with a matching ID.
        guard let skeleton = skeletons.first(where: { $0.id == id }) else {
            return nil
        }

        return hydrateProfile(skeleton)
    }

    /// Get whichever profile is marked as the default.
    /// - Returns: The default profile (hydrated), or `nil` if none is set.
    func getDefault() -> EndpointProfile? {
        let skeletons = loadProfileSkeletons()

        guard let skeleton = skeletons.first(where: { $0.isDefault }) else {
            return nil
        }

        return hydrateProfile(skeleton)
    }

    /// Save a profile. Metadata goes to UserDefaults, credentials go to Keychain.
    ///
    /// If a profile with the same ID already exists, it is replaced.
    ///
    /// - Parameter profile: The profile to save.
    /// - Throws: If the Keychain write fails.
    func save(_ profile: EndpointProfile) throws {
        // Step 1: Save credentials to the Keychain.
        try saveCredentials(for: profile)

        // Step 2: Create a "skeleton" — the profile WITHOUT sensitive data.
        let skeleton = makeProfileSkeleton(from: profile)

        // Step 3: Load existing skeletons, replace or append, then write back.
        var skeletons = loadProfileSkeletons()

        if let index = skeletons.firstIndex(where: { $0.id == profile.id }) {
            // Update existing profile in place.
            skeletons[index] = skeleton
        } else {
            // New profile — add it to the list.
            skeletons.append(skeleton)
        }

        saveProfileSkeletons(skeletons)
    }

    /// Delete a profile from both UserDefaults and Keychain.
    ///
    /// - Parameter profile: The profile to delete.
    /// - Throws: If the Keychain delete fails.
    func delete(_ profile: EndpointProfile) throws {
        // Step 1: Remove credentials from the Keychain.
        try deleteCredentials(for: profile.id)

        // Step 2: Remove the skeleton from the list.
        var skeletons = loadProfileSkeletons()
        skeletons.removeAll { $0.id == profile.id }
        saveProfileSkeletons(skeletons)
    }

    /// Mark one profile as the default, un-marking all others.
    ///
    /// - Parameter profile: The profile to set as default.
    /// - Throws: If the underlying save operation fails.
    func setDefault(_ profile: EndpointProfile) throws {
        // Load all skeletons and clear the `isDefault` flag on each one.
        var skeletons = loadProfileSkeletons()

        for index in skeletons.indices {
            // Set `isDefault` to true ONLY for the matching profile.
            skeletons[index].isDefault = (skeletons[index].id == profile.id)
        }

        saveProfileSkeletons(skeletons)
    }

    /// Quick check: can we read and write to the Keychain right now?
    func isKeychainAvailable() -> Bool {
        return KeychainHelper.isAvailable()
    }

    // MARK: - Default Profile Seeding

    /// Seeds a default "Local RTMP" profile on first launch.
    ///
    /// **Why do we do this?**
    /// The Android version of StreamCaster ships with a pre-configured
    /// "Local RTMP" profile pointing to `rtmp://192.168.0.12:1935/live`.
    /// This makes it easy for new users to test with a local RTMP server
    /// (like OBS or nginx-rtmp) without manually entering a URL.
    ///
    /// **How it works:**
    /// 1. Check the `seedProfileKey` flag in UserDefaults. If `true`, we
    ///    already seeded → return immediately. This ensures we only seed
    ///    once, even if the user deletes the profile later.
    /// 2. If no profiles exist yet (`getAll().isEmpty`), create a default
    ///    profile and save it.
    /// 3. Set the flag to `true` so we never seed again.
    private func seedDefaultProfileIfNeeded() {
        // If we've already seeded on a previous launch, skip.
        if defaults.bool(forKey: seedProfileKey) {
            return
        }

        // Only seed if the user has no profiles at all. If they already
        // have profiles (e.g., restored from a backup), don't add ours.
        if getAll().isEmpty {
            // Create a starter profile pointing to a common local RTMP
            // server address. The user can edit or delete it later.
            let defaultProfile = EndpointProfile(
                id: UUID().uuidString,
                name: "Local RTMP",
                rtmpUrl: "rtmp://192.168.0.12:1935/live",
                streamKey: "",
                username: nil,
                password: nil,
                isDefault: true
            )

            // Save the profile. If the Keychain write fails (e.g., device
            // is locked at boot), catch the error silently — seeding is a
            // nice-to-have, not critical.
            do {
                try save(defaultProfile)
            } catch {
                print("⚠️ Could not seed default profile: \(error.localizedDescription)")
                return
            }
        }

        // Mark seeding as done so we don't repeat it on future launches.
        defaults.set(true, forKey: seedProfileKey)
    }

    // MARK: - RTMP URL Parsing

    /// Parses an RTMP URL and extracts any embedded stream key.
    ///
    /// Many streaming platforms give users a single URL that contains
    /// both the server address AND the stream key, separated by the
    /// last `/`. For example:
    ///
    ///     Input:  "rtmp://live.twitch.tv/app/live_abc123"
    ///     Output: (baseURL: "rtmp://live.twitch.tv/app",
    ///              streamKey: "live_abc123")
    ///
    /// Also handles query parameters:
    ///
    ///     Input:  "rtmps://server.com/live/myKey?auth=token"
    ///     Output: (baseURL: "rtmps://server.com/live",
    ///              streamKey: "myKey?auth=token")
    ///
    /// If the URL has no embedded key (only scheme + host + one path
    /// segment), the full URL is returned as the base with an empty key.
    ///
    /// - Parameter url: The raw URL string pasted by the user.
    /// - Returns: A tuple of `(baseURL, streamKey)`.
    static func parseRTMPUrl(_ url: String) -> (baseURL: String, streamKey: String) {
        // Trim whitespace that users might accidentally paste.
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)

        // We need at least a valid-looking RTMP URL.
        guard trimmed.lowercased().hasPrefix("rtmp://") ||
              trimmed.lowercased().hasPrefix("rtmps://") else {
            // Not an RTMP URL — return as-is with no key.
            return (baseURL: trimmed, streamKey: "")
        }

        // Split the URL into the part before "?" (path) and after (query).
        // Example: "rtmp://host/live/key?auth=tok" → path = "rtmp://host/live/key", query = "auth=tok"
        let parts = trimmed.split(separator: "?", maxSplits: 1)
        let pathPart = String(parts[0])
        let queryPart = parts.count > 1 ? String(parts[1]) : nil

        // Find the scheme separator "://" so we don't accidentally split on it.
        guard let schemeEnd = pathPart.range(of: "://") else {
            return (baseURL: trimmed, streamKey: "")
        }

        // Everything after "://" is the host + path.
        let afterScheme = pathPart[schemeEnd.upperBound...]

        // Split by "/" to get path segments.
        // Example: "live.twitch.tv/app/live_abc123" → ["live.twitch.tv", "app", "live_abc123"]
        let segments = afterScheme.split(separator: "/", omittingEmptySubsequences: true)

        // We need at least 3 segments: host, app-name, stream-key.
        // If there are only 1 or 2 segments (host or host/app), there's no embedded key.
        guard segments.count >= 3 else {
            return (baseURL: trimmed, streamKey: "")
        }

        // The last segment is the stream key.
        let keySegment = String(segments.last!)

        // The base URL is everything BEFORE the last "/" in the path part.
        // We find the last "/" and slice up to it.
        guard let lastSlashIndex = pathPart.lastIndex(of: "/") else {
            return (baseURL: trimmed, streamKey: "")
        }
        let baseURL = String(pathPart[pathPart.startIndex..<lastSlashIndex])

        // If there was a query string, append it to the stream key.
        // The query often contains auth tokens that belong with the key.
        let streamKey: String
        if let query = queryPart {
            streamKey = keySegment + "?" + query
        } else {
            streamKey = keySegment
        }

        return (baseURL: baseURL, streamKey: streamKey)
    }

    // MARK: - Private Helpers — UserDefaults

    /// A stripped-down version of EndpointProfile that has NO sensitive fields.
    /// This is what we store in UserDefaults (which is NOT encrypted).
    private struct ProfileSkeleton: Codable {
        let id: String
        var name: String
        var rtmpUrl: String
        var isDefault: Bool
    }

    /// Load the array of profile skeletons from UserDefaults.
    /// Returns an empty array if nothing has been saved yet.
    private func loadProfileSkeletons() -> [ProfileSkeleton] {
        // UserDefaults stores our profiles as a JSON-encoded Data blob.
        guard let data = defaults.data(forKey: profilesKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([ProfileSkeleton].self, from: data)
        } catch {
            // If decoding fails (e.g., data corruption), start fresh.
            // In a production app we might log this error.
            return []
        }
    }

    /// Write the array of profile skeletons to UserDefaults.
    private func saveProfileSkeletons(_ skeletons: [ProfileSkeleton]) {
        do {
            let data = try JSONEncoder().encode(skeletons)
            defaults.set(data, forKey: profilesKey)
        } catch {
            // Encoding a simple Codable struct should never fail, but
            // if it does, there's not much we can do. A production app
            // would log this.
        }
    }

    /// Create a skeleton (no secrets) from a full profile.
    private func makeProfileSkeleton(from profile: EndpointProfile) -> ProfileSkeleton {
        return ProfileSkeleton(
            id: profile.id,
            name: profile.name,
            rtmpUrl: profile.rtmpUrl,
            isDefault: profile.isDefault
        )
    }

    // MARK: - Private Helpers — Keychain

    /// Keychain keys are built from the profile ID + a suffix.
    /// Example: "profile_E621E1F8_streamKey"
    private func keychainKey(profileId: String, field: String) -> String {
        return "profile_\(profileId)_\(field)"
    }

    /// Take a skeleton from UserDefaults and fill in credentials from Keychain.
    /// If a credential isn't found in the Keychain, we leave it empty/nil.
    private func hydrateProfile(_ skeleton: ProfileSkeleton) -> EndpointProfile {
        // Read each credential from the Keychain.
        let streamKey = readString(profileId: skeleton.id, field: "streamKey") ?? ""
        let username = readString(profileId: skeleton.id, field: "username")
        let password = readString(profileId: skeleton.id, field: "password")

        return EndpointProfile(
            id: skeleton.id,
            name: skeleton.name,
            rtmpUrl: skeleton.rtmpUrl,
            streamKey: streamKey,
            username: username,
            password: password,
            isDefault: skeleton.isDefault
        )
    }

    /// Save a profile's sensitive fields to the Keychain.
    private func saveCredentials(for profile: EndpointProfile) throws {
        // Always save the stream key (even if empty — so we have a consistent state).
        try saveString(profile.streamKey, profileId: profile.id, field: "streamKey")

        // Username and password are optional. Save them if present, delete if nil.
        if let username = profile.username {
            try saveString(username, profileId: profile.id, field: "username")
        } else {
            try KeychainHelper.delete(key: keychainKey(profileId: profile.id, field: "username"))
        }

        if let password = profile.password {
            try saveString(password, profileId: profile.id, field: "password")
        } else {
            try KeychainHelper.delete(key: keychainKey(profileId: profile.id, field: "password"))
        }
    }

    /// Remove all Keychain entries for a profile.
    private func deleteCredentials(for profileId: String) throws {
        try KeychainHelper.delete(key: keychainKey(profileId: profileId, field: "streamKey"))
        try KeychainHelper.delete(key: keychainKey(profileId: profileId, field: "username"))
        try KeychainHelper.delete(key: keychainKey(profileId: profileId, field: "password"))
    }

    /// Helper: Save a String to the Keychain by converting it to UTF-8 Data.
    private func saveString(_ value: String, profileId: String, field: String) throws {
        let key = keychainKey(profileId: profileId, field: field)
        let data = Data(value.utf8)
        try KeychainHelper.save(key: key, data: data)
    }

    /// Helper: Read a String from the Keychain by converting stored Data back to UTF-8.
    /// Returns `nil` if the key doesn't exist.
    private func readString(profileId: String, field: String) -> String? {
        let key = keychainKey(profileId: profileId, field: field)
        guard let data = KeychainHelper.read(key: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
