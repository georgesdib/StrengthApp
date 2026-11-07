import Foundation
import Security

protocol TokenStoring {
    func save(_ token: String) throws
    func load() -> String?
    func delete()
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "The iPhone Keychain returned status \(status)."
        }
    }
}

/// The only holder of the API token. The token never goes to UserDefaults, a file or a log.
struct KeychainTokenStore: TokenStoring {
    static let defaultService = "com.georgesdibpersonalteam.StrengthApp"
    static let defaultAccount = "api-token"

    let service: String
    let account: String

    init(service: String = Self.defaultService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }
        let query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
