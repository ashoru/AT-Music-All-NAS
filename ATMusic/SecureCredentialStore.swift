import Foundation
import Security

/// 可注入后端，测试只操作内存，不触碰用户钥匙串。
protocol CredentialBackend: Sendable {
    func read(_ key: String) -> String?
    func write(_ value: String, key: String) -> Bool
    func remove(_ key: String) -> Bool
}

struct KeychainCredentialBackend: CredentialBackend {
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.atmusic.music.credentials",
         kSecAttrAccount as String: key]
    }
    func read(_ key: String) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func write(_ value: String, key: String) -> Bool {
        let data = Data(value.utf8)
        let request = query(key)
        let update = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = request
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    func remove(_ key: String) -> Bool {
        let status = SecItemDelete(query(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

final class SecureCredentialStore: @unchecked Sendable {
    static let shared = SecureCredentialStore()
    private let backend: any CredentialBackend
    private let lock = NSLock()

    init(backend: any CredentialBackend = KeychainCredentialBackend()) {
        self.backend = backend
    }

    @discardableResult
    func setSecret(_ value: String, for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // 不先删除旧值，也不以进程内缓存冒充落盘成功。
        return backend.write(value, key: key) && backend.read(key) == value
    }
    func secret(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return backend.read(key)
    }
    @discardableResult
    func deleteSecret(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return backend.remove(key)
    }

    /// 成功写入并回读后才移除旧明文；失败保留可恢复的旧值，下次启动重试。
    @discardableResult
    func migrateLegacyPassword(defaults: UserDefaults, destinationKey: String) -> Bool {
        let legacyKey = "atmusic.synology.password"
        guard let value = defaults.string(forKey: legacyKey), !value.isEmpty else { return true }
        guard setSecret(value, for: destinationKey) else { return false }
        defaults.removeObject(forKey: legacyKey)
        return true
    }
}
