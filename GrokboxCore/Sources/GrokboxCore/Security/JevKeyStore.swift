import Foundation
import Security

/// The Jev API key, opt-in and user-supplied, lives in its own Keychain
/// service — kept out of `KeychainStore`'s IMAP-labelled namespace and never
/// written to SwiftData or `UserDefaults`. Deleted whenever Jev is turned off
/// or the app is erased. See `JevSettings.swift` and docs/PRIVACY.md.
public enum JevKeyStore {
    private static let service = "com.wesleykeetch.grokbox.jev"
    private static let account = "apiKey"

    public static func save(apiKey: String) throws {
        try? delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(apiKey.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.KeychainError.unexpectedStatus(status) }
    }

    public static func apiKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStore.KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStore.KeychainError.unexpectedStatus(status)
        }
    }
}
