import Foundation
#if canImport(Security)
import Security
#endif

/// Process-local secret persistence. Production uses the macOS Keychain;
/// tests inject `InMemorySecretStore` so they never touch the real keychain
/// or leave plaintext API keys in SQLite.
protocol SecretStore: AnyObject {
    func save(account: String, secret: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

enum SecretStoreError: Error, Equatable, LocalizedError {
    case persistFailed(String)
    case readbackMismatch
    case unavailable

    var errorDescription: String? {
        switch self {
        case .persistFailed:
            return "访问凭据没能保存，请重试。"
        case .readbackMismatch:
            return "访问凭据写完后读回来对不上，已保留原来的。"
        case .unavailable:
            return "这台 Mac 现在存不了访问凭据，请重试。"
        }
    }
}

/// Isolated dictionary used by unit tests and by HUDStore when XCTest is linked.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func save(account: String, secret: String) throws {
        lock.lock()
        items[account] = secret
        lock.unlock()
    }

    func load(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]
    }

    func delete(account: String) throws {
        lock.lock()
        items.removeValue(forKey: account)
        lock.unlock()
    }
}

/// Generic-password Keychain item store. Account names are stable references
/// written into `settings.ai`; the secret itself never goes back to SQLite.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    static let shared = KeychainSecretStore()

    private let service: String

    init(service: String = "com.wechathud.secrets") {
        self.service = service
    }

    func save(account: String, secret: String) throws {
        #if canImport(Security)
        guard let data = secret.data(using: .utf8) else {
            throw SecretStoreError.persistFailed("secret is not UTF-8")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else {
                throw SecretStoreError.persistFailed("SecItemUpdate \(update)")
            }
            return
        }
        if status != errSecItemNotFound {
            throw SecretStoreError.persistFailed("SecItemCopyMatching \(status)")
        }
        var add = query
        add.merge(attributes) { _, new in new }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw SecretStoreError.persistFailed("SecItemAdd \(added)")
        }
        #else
        throw SecretStoreError.unavailable
        #endif
    }

    func load(account: String) throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError.persistFailed("SecItemCopyMatching \(status)")
        }
        return String(data: data, encoding: .utf8)
        #else
        throw SecretStoreError.unavailable
        #endif
    }

    func delete(account: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.persistFailed("SecItemDelete \(status)")
        }
        #endif
    }
}
