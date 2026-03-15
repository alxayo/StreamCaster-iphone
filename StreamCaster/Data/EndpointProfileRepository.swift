import Foundation

// MARK: - EndpointProfileRepository
/// Manages CRUD operations for `EndpointProfile` objects. Sensitive fields
/// like `streamKey` and `password` are stored in the iOS Keychain;
/// non-sensitive metadata (name, URL, isDefault) can live in UserDefaults
/// or a local database.
///
/// All methods are synchronous for simplicity; the Keychain API is fast
/// enough that async wrappers aren't needed for the small number of
/// profiles a typical user will have.
protocol EndpointProfileRepository {

    /// Retrieve every saved endpoint profile, in no particular order.
    /// - Returns: An array of all profiles. May be empty if none exist yet.
    func getAll() -> [EndpointProfile]

    /// Look up a single profile by its unique ID.
    /// - Parameter id: The `EndpointProfile.id` to search for.
    /// - Returns: The matching profile, or `nil` if no profile has that ID.
    func getById(_ id: String) -> EndpointProfile?

    /// Get the profile that is currently marked as the default.
    /// - Returns: The default profile, or `nil` if no default has been set.
    func getDefault() -> EndpointProfile?

    /// Create or update a profile. If a profile with the same `id` already
    /// exists, it is overwritten.
    /// - Parameter profile: The profile to save.
    /// - Throws: If the Keychain write fails (e.g., device is locked).
    func save(_ profile: EndpointProfile) throws

    /// Permanently delete a profile and its Keychain entries.
    /// - Parameter profile: The profile to delete.
    /// - Throws: If the Keychain delete fails.
    func delete(_ profile: EndpointProfile) throws

    /// Mark a profile as the default (and un-mark any previous default).
    /// - Parameter profile: The profile to make default.
    /// - Throws: If the underlying save fails.
    func setDefault(_ profile: EndpointProfile) throws

    /// Quick check that the Keychain is accessible. On a locked device or
    /// in certain simulator configurations, Keychain access can be denied.
    /// - Returns: `true` if the Keychain can be read and written.
    func isKeychainAvailable() -> Bool
}
