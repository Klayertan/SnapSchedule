import Foundation
import Security

/// Stores the optional API keys in the keychain.
enum KeychainStore {
    /// Claude API key.
    static var apiKey: String? {
        get { value(for: "anthropic-api-key") }
        set { set(newValue, for: "anthropic-api-key") }
    }

    /// Key for the OpenAI-compatible server.
    static var customKey: String? {
        get { value(for: "custom-server-api-key") }
        set { set(newValue, for: "custom-server-api-key") }
    }

    private static func query(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "SnapSchedule",
            kSecAttrAccount: account,
        ]
    }

    private static func value(for account: String) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func set(_ newValue: String?, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
