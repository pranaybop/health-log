import Foundation

public enum LogError: Error, Equatable, Sendable {
    case unauthorized
    case server(String)
    case network(String)
    case decoding(String)

    public var message: String {
        switch self {
        case .unauthorized: return "Sign in again."
        case .server(let m): return m
        case .network(let m): return m
        case .decoding(let m): return "Couldn’t read the log: \(m)"
        }
    }
}

/// The two Edge Functions. Auth is a signed-in session (Authorization: Bearer) or the owner's
/// passcode (x-log-passcode); nothing else is sent. Writes are the log-write actions documented
/// in the root README (insert-only rules apply).
public enum LogAPI {
    public static let dashboardURL = URL(string: "https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-dashboard")!
    public static let writeURL = URL(string: "https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-write")!

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    /// The dashboard payload, and its raw JSON (kept as the on-device cache).
    public static func fetchDashboard(passcode: String) async throws -> (Dashboard, Data) {
        try await fetchDashboard(.passcode(passcode))
    }

    public static func fetchDashboard(_ credential: LogCredential) async throws -> (Dashboard, Data) {
        let data = try await withRetry(credential) { cred in
            var req = URLRequest(url: dashboardURL)
            authorize(&req, cred)
            let (data, response) = try await send(req)
            try check(response, data)
            return data
        }
        do { return (try Dashboard.decode(data), data) }
        catch { throw LogError.decoding(String(describing: error)) }
    }

    static func authorize(_ req: inout URLRequest, _ credential: LogCredential) {
        switch credential {
        case .session(let token): req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .passcode(let code): req.setValue(code, forHTTPHeaderField: "x-log-passcode")
        }
    }

    /// A session that comes back 401 gets one refresh and one more try.
    private static func withRetry<T>(_ credential: LogCredential, _ run: (LogCredential) async throws -> T) async throws -> T {
        do { return try await run(credential) }
        catch LogError.unauthorized {
            guard case .session = credential, let fresh = await LogCredentials.shared.forceRefresh() else { throw LogError.unauthorized }
            return try await run(fresh)
        }
    }

    /// PUT bytes to a signed Storage URL. The URL already carries its own token.
    public static func putSigned(_ url: URL, body: Data, contentType: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = 60
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("max-age=3600", forHTTPHeaderField: "cache-control")
        req.httpBody = body
        let (data, response) = try await send(req)
        guard let http = response as? HTTPURLResponse else { throw LogError.network("No response.") }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let snippet = bodyText.count > 180 ? String(bodyText.prefix(180)) : bodyText
            throw LogError.server(snippet.isEmpty ? "The photo upload returned \(http.statusCode)." : snippet)
        }
    }

    /// POST {action, payload} to log-write. Returns the response JSON (counts, ok, etc.).
    @discardableResult
    public static func write(_ action: String, payload: [String: Any], passcode: String) async throws -> [String: Any] {
        try await write(action, payload: payload, credential: .passcode(passcode))
    }

    @discardableResult
    public static func write(_ action: String, payload: [String: Any], credential: LogCredential) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["action": action, "payload": payload])
        let data = try await withRetry(credential) { cred in
            var req = URLRequest(url: writeURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authorize(&req, cred)
            req.httpBody = body
            let (data, response) = try await send(req)
            try check(response, data)
            return data
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch { throw LogError.network("Couldn’t reach the log. Check your connection.") }
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LogError.network("No response.") }
        if http.statusCode == 401 { throw LogError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (body?["error"] as? String) ?? "The log returned \(http.statusCode)."
            throw LogError.server(msg)
        }
    }
}
