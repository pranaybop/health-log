import Foundation

/// In-app meal logging for people without the Log bot: they describe a meal, their own AI key
/// estimates it, they review the items, and the app saves them (log-write meal_log).
///
/// The key stays in this phone's Keychain and goes straight to the provider; it never reaches the
/// log. Nothing is saved until the person taps Save.
public enum MealAIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case openai, anthropic, google, xai

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .google: return "Google (Gemini)"
        case .xai: return "xAI (Grok)"
        }
    }

    /// A small, fast model. People can type another one.
    public var defaultModel: String {
        switch self {
        case .openai: return "gpt-4.1-mini"
        case .anthropic: return "claude-haiku-5-5"
        case .google: return "gemini-2.5-flash"
        case .xai: return "grok-4-fast"
        }
    }

    public var keyHint: String {
        switch self {
        case .openai: return "sk-…"
        case .anthropic: return "sk-ant-…"
        case .google: return "AIza…"
        case .xai: return "xai-…"
        }
    }
}

public struct MealAIConfig: Codable, Sendable, Equatable {
    public var provider: MealAIProvider
    public var model: String
    public var apiKey: String

    public init(provider: MealAIProvider, model: String, apiKey: String) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
    }

    /// The saved choice and key (Keychain). Never log or print the key.
    public static func load() -> MealAIConfig? {
        guard let data = KeychainItem.read("meal-ai"), let c = try? JSONDecoder().decode(MealAIConfig.self, from: data),
              !c.apiKey.isEmpty else { return nil }
        return c
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainItem.write("meal-ai", data)
    }

    public static func clear() { KeychainItem.delete("meal-ai") }
}

/// One estimated food.
public struct MealItem: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var item: String
    public var quantity: String?
    public var calories: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    public var fiberG: Double?

    public init(item: String, quantity: String? = nil, calories: Double? = nil, proteinG: Double? = nil,
                carbsG: Double? = nil, fatG: Double? = nil, fiberG: Double? = nil) {
        self.item = item
        self.quantity = quantity
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
    }

    enum CodingKeys: String, CodingKey { case item, quantity, calories, proteinG, carbsG, fatG, fiberG }

    /// The meal_log payload entry.
    public var payload: [String: Any] {
        var p: [String: Any] = ["item": item]
        if let quantity, !quantity.isEmpty { p["quantity"] = quantity }
        if let calories { p["calories"] = (calories * 10).rounded() / 10 }
        if let proteinG { p["protein_g"] = (proteinG * 10).rounded() / 10 }
        if let carbsG { p["carbs_g"] = (carbsG * 10).rounded() / 10 }
        if let fatG { p["fat_g"] = (fatG * 10).rounded() / 10 }
        if let fiberG { p["fiber_g"] = (fiberG * 10).rounded() / 10 }
        return p
    }
}

public struct MealEstimate: Sendable, Equatable {
    public var items: [MealItem]
    /// breakfast, lunch, dinner or snack, when the description says.
    public var mealType: String?
}

enum AIRequest {
    /// Current Messages API version (the one Ask sends). A meal estimate does not send
    /// temperature, top_p or top_k, which this version rejects.
    static let anthropicVersion = "2026-10-21"

    static func model(_ config: MealAIConfig) -> String {
        config.model.trimmingCharacters(in: .whitespaces).isEmpty ? config.provider.defaultModel : config.model
    }

    static func make(_ config: MealAIConfig, model: String, timeout: TimeInterval, body: [String: Any]) throws -> URLRequest {
        var req: URLRequest
        switch config.provider {
        case .openai, .xai:
            let base = config.provider == .openai ? "https://api.openai.com/v1/chat/completions" : "https://api.x.ai/v1/chat/completions"
            req = URLRequest(url: URL(string: base)!)
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .google:
            let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escaped):generateContent")!)
            req.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func failure(status: Int, name: String, model: String, json: [String: Any] = [:]) -> LogError {
        if status == 401 || status == 403 { return .server("\(name) didn’t accept the key. Check it in Account.") }
        if status == 404 { return .server("\(name) doesn’t know the model “\(model)”. Change it in Account.") }
        if status == 429 { return .server("\(name) says the key is out of quota or rate-limited.") }
        let msg = (json["error"] as? [String: Any])?["message"] as? String
        return .server(msg ?? "\(name) returned \(status).")
    }
}

public enum MealAI {
    static let instructions = """
    You estimate nutrition for a food log. The user describes what they ate. Reply with JSON only, \
    no prose, in this shape: {"meal_type": "breakfast|lunch|dinner|snack|null", "items": [{"item": \
    "short name", "quantity": "amount as described", "calories": number, "protein_g": number, \
    "carbs_g": number, "fat_g": number, "fiber_g": number}]}. One entry per distinct food or drink. \
    Use typical US portions when the amount isn't given. Numbers are best estimates, never ranges. \
    If the text doesn't describe food, reply {"items": []}.
    """

    /// Ask the person's provider for an estimate. Throws LogError with a sentence to show.
    public static func estimate(_ text: String, config: MealAIConfig, session: URLSession = .shared) async throws -> MealEstimate {
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw LogError.server("Describe what you ate.") }
        let req = try request(description, config: config)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw LogError.network("Couldn’t reach \(config.provider.name). Check your connection.") }
        guard let http = response as? HTTPURLResponse else { throw LogError.network("No response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw AIRequest.failure(status: http.statusCode, name: config.provider.name, model: config.model)
        }
        guard let reply = replyText(data, provider: config.provider) else {
            throw LogError.server("Couldn’t read \(config.provider.name)’s answer.")
        }
        let estimate = parse(reply)
        guard !estimate.items.isEmpty else { throw LogError.server("That didn’t read as food. Try describing the meal again.") }
        return estimate
    }

    static func request(_ description: String, config: MealAIConfig) throws -> URLRequest {
        let model = AIRequest.model(config)
        var body: [String: Any]
        switch config.provider {
        case .openai, .xai:
            body = ["model": model,
                    "messages": [["role": "system", "content": instructions], ["role": "user", "content": description]],
                    "temperature": 0.2]
            if config.provider == .openai { body["response_format"] = ["type": "json_object"] }
        case .anthropic:
            body = ["model": model, "max_tokens": 1024, "system": instructions,
                    "messages": [["role": "user", "content": description]]]
        case .google:
            body = ["systemInstruction": ["parts": [["text": instructions]]],
                    "contents": [["role": "user", "parts": [["text": description]]]],
                    "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2]]
        }
        return try AIRequest.make(config, model: model, timeout: 45, body: body)
    }

    /// The model's text from each provider's response shape.
    static func replyText(_ data: Data, provider: MealAIProvider) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch provider {
        case .openai, .xai:
            let choices = json["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            return message?["content"] as? String
        case .anthropic:
            let content = json["content"] as? [[String: Any]]
            return content?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        case .google:
            let candidates = json["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            return parts?.compactMap { $0["text"] as? String }.joined()
        }
    }

    /// Reads the JSON reply, tolerating code fences or text around it.
    public static func parse(_ reply: String) -> MealEstimate {
        var text = reply
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return MealEstimate(items: [], mealType: nil)
        }
        func num(_ v: Any?) -> Double? {
            if let d = v as? Double { return d.isFinite && d >= 0 ? d : nil }
            if let s = v as? String { return Double(s.filter { "0123456789.".contains($0) }) }
            return nil
        }
        let rows = (json["items"] as? [[String: Any]]) ?? []
        let items: [MealItem] = rows.prefix(30).compactMap { r in
            guard let name = (r["item"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return MealItem(item: String(name.prefix(200)), quantity: (r["quantity"] as? String).map { String($0.prefix(100)) },
                            calories: num(r["calories"]).map { min($0, 5000) }, proteinG: num(r["protein_g"]).map { min($0, 500) },
                            carbsG: num(r["carbs_g"]).map { min($0, 1000) }, fatG: num(r["fat_g"]).map { min($0, 500) },
                            fiberG: num(r["fiber_g"]).map { min($0, 200) })
        }
        let type = (json["meal_type"] as? String)?.lowercased()
        let mealType = ["breakfast", "lunch", "dinner", "snack"].contains(type ?? "") ? type : nil
        return MealEstimate(items: items, mealType: mealType)
    }

    /// The meal_log payload for reviewed items.
    public static func payload(_ items: [MealItem], mealType: String?, eatenAt: Date, usedAI: Bool) -> [String: Any] {
        var p: [String: Any] = ["items": items.map(\.payload), "source": usedAI ? "app-ai" : "app"]
        if let mealType { p["meal_type"] = mealType }
        let f = ISO8601DateFormatter()
        p["eaten_at"] = f.string(from: eatenAt)
        return p
    }
}
