import Foundation

/// The Log passcode in the iPhone Keychain (this device only, readable after first unlock so a
/// background sync can use it). Same item the 1.2 shell used, so nothing needs re-entering.
/// Never log or print the value.
public enum PasscodeStore {
    private static let account = "passcode"

    public static func read() -> String? {
        guard let data = KeychainItem.read(account),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    public static func write(_ passcode: String) {
        guard !passcode.isEmpty else { return }
        KeychainItem.write(account, Data(passcode.utf8))
    }

    public static func clear() {
        KeychainItem.delete(account)
    }
}
