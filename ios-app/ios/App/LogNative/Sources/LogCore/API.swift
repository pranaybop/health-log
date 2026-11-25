import Foundation

public enum LogError: Error, Equatable, Sendable {
    case unauthorized
    case server(String)
    case network(String)
    case decoding(String)

    public var message: String {
        switch self {
        case .unauthorized: return "Passcode was rejected."
        case .server(let m): return m
        case .network(let m): return m
        case .decoding(let m): return "Couldn’t read the log: \(m)"
        }
    }
}

/// The two Edge Functions. Auth is the x-log-passcode header; nothing else is sent.
/// Writes are the log-write actions documented in the root README (insert-only rules apply).
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
        var req = URLRequest(url: dashboardURL)
        req.setValue(passcode, forHTTPHeaderField: "x-log-passcode")
        let (data, response) = try await send(req)
        try check(response, data)
        do { return (try Dashboard.decode(data), data) }
        catch { throw LogError.decoding(String(describing: error)) }
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
        var req = URLRequest(url: writeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(passcode, forHTTPHeaderField: "x-log-passcode")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "payload": payload])
        let (data, response) = try await send(req)
        try check(response, data)
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
