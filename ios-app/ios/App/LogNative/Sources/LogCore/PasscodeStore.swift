import Foundation
import Security

/// The Log passcode in the iPhone Keychain (this device only, readable after first unlock so a
/// background sync can use it). Same item the 1.2 shell used, so nothing needs re-entering.
/// Never log or print the value.
public enum PasscodeStore {
    private static let service = "com.pranaybop.log"
    private static let account = "passcode"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    public static func write(_ passcode: String) {
        guard !passcode.isEmpty else { return }
        let attrs: [String: Any] = [kSecValueData as String: Data(passcode.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
