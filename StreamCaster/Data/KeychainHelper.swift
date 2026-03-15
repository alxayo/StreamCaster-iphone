import Foundation
import Security

// MARK: - KeychainHelper
/// KeychainHelper provides a simple interface to iOS Keychain Services.
///
/// The Keychain is a secure, encrypted storage provided by the operating
/// system. We use it to store sensitive data like stream keys and passwords.
///
/// All items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
///   - Data is only accessible when the device is unlocked
///   - Data is NOT transferred to new devices or backups
///   - Data is protected by the device's Secure Enclave hardware
///
/// Think of the Keychain as a locked safe for small pieces of data.
/// Each item is identified by a (service, account) pair — similar to
/// a dictionary key. We use the app's bundle-based service name and
/// the profile field name as the account.
struct KeychainHelper {

    // MARK: - Constants

    /// Service identifier for our app's keychain items.
    /// All items share this service so they're grouped together.
    static let service = "com.port80.app.keychain"

    // MARK: - Errors

    /// Errors that can occur during Keychain operations.
    /// We wrap the raw `OSStatus` codes so callers get friendly messages.
    enum KeychainError: LocalizedError {
        /// The Keychain refused to save (e.g., device locked, out of space).
        case saveFailed(status: OSStatus)
        /// The Keychain refused to delete an item.
        case deleteFailed(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed with status \(status)"
            case .deleteFailed(let status):
                return "Keychain delete failed with status \(status)"
            }
        }
    }

    // MARK: - Public Methods

    /// Save data to the Keychain.
    ///
    /// If an item with the same key already exists, it is deleted first
    /// and then re-added. This "delete-then-add" approach is simpler and
    /// more reliable than trying to update in place.
    ///
    /// - Parameters:
    ///   - key: A unique string identifying this item (e.g., "profile_abc_streamKey").
    ///   - data: The raw bytes to store.
    /// - Throws: `KeychainError.saveFailed` if the OS rejects the write.
    static func save(key: String, data: Data) throws {
        // Step 1: Remove any existing item with this key.
        // We ignore the result — it's fine if there was nothing to delete.
        try? delete(key: key)

        // Step 2: Build the query dictionary that describes what to store.
        // Each key (kSec…) tells the Keychain one piece of information:
        let query: [String: Any] = [
            // What kind of item? A generic password (catch-all for blobs).
            kSecClass as String: kSecClassGenericPassword,
            // Our app's service name — groups items together.
            kSecAttrService as String: service,
            // The unique account name within the service.
            kSecAttrAccount as String: key,
            // The actual secret data to store.
            kSecValueData as String: data,
            // Security level: accessible only when the device is unlocked,
            // and NEVER migrated to a new device or iCloud backup.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            // Don't sync to iCloud Keychain — keeps secrets on this device only.
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]

        // Step 3: Ask the OS to add the item.
        let status = SecItemAdd(query as CFDictionary, nil)

        // Step 4: Check the result. `errSecSuccess` (0) means it worked.
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status: status)
        }
    }

    /// Read data from the Keychain.
    ///
    /// - Parameter key: The unique string used when the item was saved.
    /// - Returns: The stored data, or `nil` if no item exists for this key.
    static func read(key: String) -> Data? {
        // Build a query that describes what we're looking for.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Tell the Keychain to return the stored data (not just metadata).
            kSecReturnData as String: kCFBooleanTrue!,
            // We only expect one match — return the first one.
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Must match the same accessibility & sync settings we used to save.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]

        // SecItemCopyMatching writes the result into `result`.
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // If the status isn't success, the item doesn't exist (or can't be read).
        guard status == errSecSuccess else {
            return nil
        }

        // Cast the result to Data. The Keychain always returns Data for passwords.
        return result as? Data
    }

    /// Delete data from the Keychain.
    ///
    /// - Parameter key: The unique string identifying the item to remove.
    /// - Throws: `KeychainError.deleteFailed` if the OS rejects the delete
    ///   (but NOT if the item simply doesn't exist — that's fine).
    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]

        let status = SecItemDelete(query as CFDictionary)

        // `errSecItemNotFound` means the item was already gone — that's OK.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Check if Keychain is available.
    ///
    /// On some simulator configurations or when the device is locked,
    /// the Keychain may not be accessible. This method does a quick
    /// write-read-delete cycle to verify everything works.
    ///
    /// - Returns: `true` if the Keychain can be read and written.
    static func isAvailable() -> Bool {
        let testKey = "com.port80.app.keychain.availability_test"
        let testData = Data("test".utf8)

        do {
            // Try a full save → read → delete cycle.
            try save(key: testKey, data: testData)
            let readBack = read(key: testKey)
            try delete(key: testKey)
            // Success only if we got back what we wrote.
            return readBack == testData
        } catch {
            return false
        }
    }
}
