import Foundation
import Security

enum DeepSeekKeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        switch self {
        case .status(let status): return "Keychain error \(status)."
        }
    }
}

protocol DeepSeekKeyStoring {
    func load() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

/// Device-only Keychain storage; no iCloud sync and no UserDefaults fallback.
final class KeychainDeepSeekKeyStore: DeepSeekKeyStoring {
    private let service = "com.georgesdib.StrengthApp.deepseek"
    private let account = "api-key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DeepSeekKeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        try delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeepSeekKeychainError.status(status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekKeychainError.status(status)
        }
    }
}
