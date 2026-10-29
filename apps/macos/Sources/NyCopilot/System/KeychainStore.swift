import Foundation
import Security

/// Store the single provider API key without writing it to defaults or project files.
enum KeychainStore {
    private static let service = "dev.nycopilot.NyCopilot"
    private static let account = "provider-api-key"
    /// NyTranslate kept its key here; it is moved over the first time a key is needed.
    private static let legacy = (service: "dev.nycopilot.NyTranslate", account: "translation-api-key")

    private static func query(service: String = service, account: String = account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// An absent credential is valid for a local server; other failures remain visible.
    static func read() throws -> String {
        if let key = try read(query()) { return key }
        guard let key = try read(query(service: legacy.service, account: legacy.account)) else { return "" }
        try write(key)
        SecItemDelete(query(service: legacy.service, account: legacy.account) as CFDictionary)
        return key
    }

    /// Checks presence through attributes only, so Settings can say "saved" without unlocking the secret.
    static var hasKey: Bool {
        [query(), query(service: legacy.service, account: legacy.account)].contains { base in
            var attributes = base
            attributes[kSecReturnAttributes as String] = true
            return SecItemCopyMatching(attributes as CFDictionary, nil) == errSecSuccess
        }
    }

    /// Update in place to preserve the old key if a write fails; blank explicitly removes it.
    static func write(_ key: String) throws {
        if key.isEmpty {
            for item in [query(), query(service: legacy.service, account: legacy.account)] {
                let status = SecItemDelete(item as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            }
            return
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query().merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static func read(_ base: [String: Any]) throws -> String? {
        var attributes = base
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw Failure(status: status) }
        return key
    }

    /// Report the system status, never credential contents.
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Couldn’t access the macOS Keychain (\(status)). Unlock it and try again." }
    }
}
