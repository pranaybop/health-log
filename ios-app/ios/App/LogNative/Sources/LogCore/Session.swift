import Foundation
import Security

// Accounts (from 2.0). A person signs in with Google or an email and password; the owner can also
// keep using the passcode. The app never holds a Supabase key: sign-in goes through the log-auth
// Edge Function, and every request carries either the session's access token or the passcode.

/// How a request proves who it is for.
public enum LogCredential: Sendable, Equatable {
    /// A signed-in account (Authorization: Bearer).
    case session(String)
    /// The owner's passcode (x-log-passcode).
    case passcode(String)
}

/// A signed-in session, kept in the Keychain. Never log or print the tokens.
public struct AuthSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Seconds since 1970.
    public var expiresAt: Double
    public var userId: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Double, userId: String, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userId = userId
        self.email = email
    }

    /// True when the access token runs out within `margin` seconds.
    public func expiresSoon(now: Date = Date(), margin: Double = 120) -> Bool {
        expiresAt - now.timeIntervalSince1970 < margin
    }
}

/// Keychain items for the app (this device only, readable after first unlock so background work
/// can use them). Same service as the passcode.
enum KeychainItem {
    static let service = "com.pranaybop.log"

    static func read(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, !data.isEmpty else { return nil }
        return data
    }

    static func write(_ account: String, _ data: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

public enum SessionStore {
    private static let account = "session"

    public static func read() -> AuthSession? {
        guard let data = KeychainItem.read(account) else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    public static func write(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        KeychainItem.write(account, data)
    }

    public static func clear() { KeychainItem.delete(account) }
}

/// The credential for the next request: a signed-in session first (refreshed when it's about to
/// run out), else the passcode. One refresh at a time, shared by the app, background Apple Health
/// sync and the Live Activity buttons.
public actor LogCredentials {
    public static let shared = LogCredentials()

    private var refreshing: Task<AuthSession?, Never>?

    public func current() async -> LogCredential? {
        if let s = SessionStore.read() {
            if !s.expiresSoon() { return .session(s.accessToken) }
            if let fresh = await refreshed(s) { return .session(fresh.accessToken) }
            // Refresh failed (offline, say): the old token may still have a little time.
            if s.expiresAt > Date().timeIntervalSince1970 { return .session(s.accessToken) }
            if let code = PasscodeStore.read() { return .passcode(code) }
            return .session(s.accessToken)
        }
        if let code = PasscodeStore.read() { return .passcode(code) }
        return nil
    }

    /// Refresh now (after a 401 on a session request). Nil when the session can't be renewed.
    public func forceRefresh() async -> LogCredential? {
        guard let s = SessionStore.read(), let fresh = await refreshed(s) else { return nil }
        return .session(fresh.accessToken)
    }

    private func refreshed(_ s: AuthSession) async -> AuthSession? {
        if let task = refreshing { return await task.value }
        let task = Task<AuthSession?, Never> {
            do {
                let result = try await LogAuth.refresh(s.refreshToken)
                SessionStore.write(result.session)
                return result.session
            } catch LogError.unauthorized {
                SessionStore.clear()
                return nil
            } catch {
                return nil
            }
        }
        refreshing = task
        let value = await task.value
        refreshing = nil
        return value
    }
}

/// The log-auth Edge Function.
public enum LogAuth {
    public static let url = URL(string: "https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-auth")!
    /// The address Google sign-in returns to. Must be in Supabase Auth's redirect URLs.
    public static let callbackScheme = "com.pranaybop.log"
    public static let redirectURL = "com.pranaybop.log://auth-callback"

    public struct Result: Sendable {
        public var session: AuthSession
        /// This account holds the owner's log (the passcode log).
        public var owner: Bool
    }

    public static func signIn(email: String, password: String) async throws -> Result {
        try await sessionCall(["action": "signin", "email": email, "password": password])
    }

    public static func signUp(email: String, password: String) async throws -> Result {
        try await sessionCall(["action": "signup", "email": email, "password": password])
    }

    public static func refresh(_ refreshToken: String) async throws -> Result {
        try await sessionCall(["action": "refresh", "refresh_token": refreshToken])
    }

    /// The Google sign-in page to open in a web authentication session.
    public static func googleURL(codeChallenge: String) async throws -> URL {
        let json = try await call(["action": "google_url", "redirect_to": redirectURL, "code_challenge": codeChallenge])
        guard let s = json["url"] as? String, let u = URL(string: s) else { throw LogError.server("Couldn’t start Google sign-in.") }
        return u
    }

    public static func googleFinish(code: String, verifier: String) async throws -> Result {
        try await sessionCall(["action": "google_finish", "auth_code": code, "code_verifier": verifier])
    }

    public static func appleFinish(idToken: String, nonce: String?) async throws -> Result {
        var body: [String: Any] = ["action": "apple_finish", "id_token": idToken]
        if let nonce { body["nonce"] = nonce }
        return try await sessionCall(body)
    }

    /// Sends a reset email. Returns the sentence to show.
    public static func resetPassword(email: String) async throws -> String {
        let json = try await call(["action": "reset", "email": email])
        return (json["message"] as? String) ?? "Check your email."
    }

    public static func signOut(accessToken: String) async {
        _ = try? await call(["action": "signout"], bearer: accessToken)
    }

    /// Move the passcode log to this account (once). Throws LogError with a sentence to show.
    public static func claim(accessToken: String, passcode: String) async throws {
        _ = try await call(["action": "claim"], bearer: accessToken, passcode: passcode)
    }

    /// Whether this account holds the owner's log.
    public static func isOwner(accessToken: String) async throws -> Bool {
        let json = try await call(["action": "me"], bearer: accessToken)
        return (json["owner"] as? Bool) ?? false
    }

    // MARK: Plumbing

    private static func sessionCall(_ body: [String: Any]) async throws -> Result {
        let json = try await call(body)
        guard let s = json["session"] as? [String: Any],
              let access = s["access_token"] as? String, !access.isEmpty,
              let refresh = s["refresh_token"] as? String,
              let user = s["user"] as? [String: Any], let id = user["id"] as? String else {
            throw LogError.server("Sign-in didn’t return a session.")
        }
        let expires = (s["expires_at"] as? Double) ?? (s["expires_at"] as? Int).map { Double($0) } ?? Date().timeIntervalSince1970 + 3600
        let session = AuthSession(accessToken: access, refreshToken: refresh, expiresAt: expires, userId: id, email: user["email"] as? String)
        return Result(session: session, owner: (json["owner"] as? Bool) ?? false)
    }

    @discardableResult
    static func call(_ body: [String: Any], bearer: String? = nil, passcode: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let passcode { req.setValue(passcode, forHTTPHeaderField: "x-log-passcode") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw LogError.network("Couldn’t reach the log. Check your connection.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse else { throw LogError.network("No response.") }
        if (200..<300).contains(http.statusCode) { return json }
        let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "That didn’t work (\(http.statusCode))."
        if http.statusCode == 401 && body["action"] as? String == "refresh" { throw LogError.unauthorized }
        throw LogError.server(message)
    }
}
