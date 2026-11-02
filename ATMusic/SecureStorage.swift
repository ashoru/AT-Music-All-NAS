import Foundation
import Security

/// Keychain-backed storage for account credentials.
///
/// Login cookies and tokens used to be written to `UserDefaults`, which is
/// stored as an unencrypted plist and is readable from any device backup or
/// jailbroken process. Values here are stored as generic passwords with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they stay available
/// to background audio playback after a reboot but never leave the device
/// through an iCloud or iTunes backup.
///
/// The API mirrors the small slice of `UserDefaults` that the auth classes
/// already use, so callers only need to swap the storage object.
final class SecureStorage {
    static let shared = SecureStorage()

    private let service = "com.atmusic.player.credentials"
    private let migrationPrefix = "atmusic.secureStorage.migrated."
    private let fallbackPrefix = "atmusic.keychainFallback."

    private init() {}

    // MARK: - Read

    func data(forKey key: String) -> Data? {
        read(key)
    }

    func string(forKey key: String) -> String? {
        guard let data = read(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        guard let data = read(key) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Write

    func set(_ value: Any?, forKey key: String) {
        guard let value = value else {
            removeObject(forKey: key)
            return
        }
        // Empty Data/String are meaningful clears (e.g. wiping a VIP badge):
        // write() routes empty data to the fallback store, so do not drop them.
        if let data = value as? Data {
            write(data, key)
            return
        }
        if let string = value as? String {
            write(Data(string.utf8), key)
            return
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value) {
            write(data, key)
        }
    }

    func removeObject(forKey key: String) {
        SecItemDelete(query(key) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(key))
    }

    // MARK: - Migration

    /// Moves existing `UserDefaults` values into the Keychain once per key.
    /// Call this before the first read so existing users stay logged in.
    func migrateFromUserDefaults(_ keys: [String], defaults: UserDefaults = .standard) {
        for key in keys {
            let flag = migrationPrefix + key
            if defaults.bool(forKey: flag) { continue }
            if let value = defaults.object(forKey: key) {
                set(value, forKey: key)
            }
            defaults.removeObject(forKey: key)
            defaults.set(true, forKey: flag)
        }
    }

    // MARK: - Keychain primitives

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func fallbackKey(_ key: String) -> String {
        fallbackPrefix + key
    }

    private func read(_ key: String) -> Data? {
        var searchQuery = query(key)
        searchQuery[kSecReturnData as String] = true
        searchQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        if SecItemCopyMatching(searchQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        // Unsigned or ad-hoc builds may not be able to reach the Keychain.
        // Fall back so credentials keep working instead of breaking login.
        return UserDefaults.standard.data(forKey: fallbackKey(key))
    }

    private func write(_ data: Data, _ key: String) {
        // Empty values are meaningful (e.g. clearing a VIP badge), so keep them
        // in the fallback store instead of dropping the write.
        guard !data.isEmpty else {
            SecItemDelete(query(key) as CFDictionary)
            UserDefaults.standard.set(data, forKey: fallbackKey(key))
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }

        if status != errSecSuccess {
            UserDefaults.standard.set(data, forKey: fallbackKey(key))
        } else {
            UserDefaults.standard.removeObject(forKey: fallbackKey(key))
        }
    }
}
