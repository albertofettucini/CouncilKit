import Foundation
import Security

/// Secure storage for API keys, backed by the macOS Keychain.
/// Keys are never written to disk in plaintext, to UserDefaults, or to the repo.
public enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.joseph.Council"

    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    /// Save (or overwrite) a secret for the given account.
    public static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)

        // Remove any existing item first, then add a fresh one (simpler than an update).
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// CI escape hatch (CLI `--allow-env-keys` only): lets COUNCIL_KEY_<PROVIDER> env vars
    /// override Keychain reads. NEVER enabled by default; the CLI prints a warning when it is.
    public static var allowEnvOverride = false

    /// Read the secret for the given account, or nil if none is stored.
    public static func read(account: String) throws -> String? {
        if allowEnvOverride,
           let suffix = account.split(separator: ".").last,
           let env = ProcessInfo.processInfo.environment["COUNCIL_KEY_\(suffix.uppercased())"],
           !env.isEmpty {
            return env
        }
        return try keychainRead(account: account)
    }

    private static func keychainRead(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Delete the secret for the given account. Returns true if it is gone afterwards.
    @discardableResult
    public static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
