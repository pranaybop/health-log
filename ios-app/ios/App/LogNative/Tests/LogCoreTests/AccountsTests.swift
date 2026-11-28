import XCTest
@testable import LogCore

final class AccountsTests: XCTestCase {
    func testMealReplyParsesThroughCodeFences() {
        let reply = """
        Here you go:
        ```json
        {"meal_type": "Lunch", "items": [{"item": "Chicken bowl", "quantity": "1 bowl", "calories": 620, "protein_g": "45", "carbs_g": 60, "fat_g": 18}, {"item": "", "calories": 10}]}
        ```
        """
        let e = MealAI.parse(reply)
        XCTAssertEqual(e.mealType, "lunch")
        XCTAssertEqual(e.items.count, 1)
        XCTAssertEqual(e.items.first?.item, "Chicken bowl")
        XCTAssertEqual(e.items.first?.proteinG, 45)
        XCTAssertEqual(e.items.first?.calories, 620)
    }

    func testMealReplyThatIsNotFoodIsEmpty() {
        XCTAssertTrue(MealAI.parse("{\"items\": []}").items.isEmpty)
        XCTAssertTrue(MealAI.parse("I can't help with that.").items.isEmpty)
    }

    func testMealPayloadRoundsAndTags() {
        let p = MealAI.payload([MealItem(item: "Toast", calories: 120.04, proteinG: 4.26)], mealType: "breakfast", eatenAt: Date(timeIntervalSince1970: 0), usedAI: true)
        XCTAssertEqual(p["source"] as? String, "app-ai")
        XCTAssertEqual(p["meal_type"] as? String, "breakfast")
        let item = (p["items"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["calories"] as? Double, 120)
        XCTAssertEqual(item?["protein_g"] as? Double, 4.3)
    }

    func testCentralNoonIsUnchanged() {
        XCTAssertEqual(LogTime.noon("2026-11-24").timeIntervalSince1970, 1795543200)
        XCTAssertEqual(LogTime.dayKey(LogTime.noon("2026-11-24")), "2026-11-24")
        XCTAssertEqual(LogTime.dayDiff("2026-12-01", "2026-11-24"), 7)
        XCTAssertEqual(LogTime.monday("2026-11-26"), "2026-11-23")
    }

    func testAnotherZoneKeepsDayKeys() {
        let original = LogTime.zone
        defer { LogTime.use(zone: original) }
        for id in ["Pacific/Auckland", "Pacific/Kiritimati", "Asia/Kolkata", "Europe/London", "Pacific/Honolulu"] {
            LogTime.use(zone: TimeZone(identifier: id)!)
            XCTAssertEqual(LogTime.dayKey(LogTime.noon("2026-11-24")), "2026-11-24", id)
            XCTAssertEqual(LogTime.dayKey(LogTime.startOfDay("2026-11-24")), "2026-11-24", id)
            XCTAssertEqual(LogTime.shift("2026-11-24", 7), "2026-12-01", id)
            XCTAssertEqual(LogTime.monday("2026-11-26"), "2026-11-23", id)
        }
    }

    func testSessionExpiry() {
        let s = AuthSession(accessToken: "a", refreshToken: "r", expiresAt: 1_000, userId: "u", email: nil)
        XCTAssertTrue(s.expiresSoon(now: Date(timeIntervalSince1970: 900)))
        XCTAssertFalse(s.expiresSoon(now: Date(timeIntervalSince1970: 100)))
    }

    func testMealAndAskShareTheProviderRequest() throws {
        let anthropic = MealAIConfig(provider: .anthropic, model: "", apiKey: "sk-ant-test")
        let meal = try MealAI.request("eggs", config: anthropic)
        let ask = try AskCloud.request(anthropic, system: "sys", messages: [["role": "user", "content": "hi"]], tools: false)
        XCTAssertEqual(meal.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(ask.value(forHTTPHeaderField: "anthropic-version"), meal.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertEqual(meal.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(ask.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(meal.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(ask.url, meal.url)
        XCTAssertEqual(meal.timeoutInterval, 45)
        XCTAssertEqual(ask.timeoutInterval, 120)
        let mealBody = try json(meal)
        let askBody = try json(ask)
        XCTAssertEqual(mealBody["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(askBody["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(mealBody["max_tokens"] as? Int, 1024)
        XCTAssertEqual(askBody["max_tokens"] as? Int, 16000)

        let openai = MealAIConfig(provider: .openai, model: " custom ", apiKey: "sk-test")
        let mealOpenAI = try MealAI.request("eggs", config: openai)
        XCTAssertEqual(mealOpenAI.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(mealOpenAI.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let openAIBody = try json(mealOpenAI)
        XCTAssertEqual(openAIBody["model"] as? String, " custom ")
        XCTAssertEqual((openAIBody["temperature"] as? NSNumber)?.doubleValue ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual((openAIBody["response_format"] as? [String: Any])?["type"] as? String, "json_object")

        let xai = MealAIConfig(provider: .xai, model: "grok-4-fast", apiKey: "xai-test")
        let askXAI = try AskCloud.request(xai, system: "sys", messages: [["role": "user", "content": "q"]], tools: true)
        XCTAssertEqual(askXAI.url?.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(askXAI.value(forHTTPHeaderField: "Authorization"), "Bearer xai-test")
        let xaiBody = try json(askXAI)
        XCTAssertNil(xaiBody["temperature"])
        XCTAssertNotNil(xaiBody["tools"])

        let google = MealAIConfig(provider: .google, model: "gemini-2.5-flash", apiKey: "AIza-test")
        let mealGoogle = try MealAI.request("eggs", config: google)
        XCTAssertEqual(mealGoogle.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(mealGoogle.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")
    }

    func testProviderStatusSentences() {
        XCTAssertEqual(AIRequest.failure(status: 401, name: "OpenAI", model: "m"),
                       .server("OpenAI didn’t accept the key. Check it in Account."))
        XCTAssertEqual(AIRequest.failure(status: 403, name: "Anthropic (Claude)", model: "m"),
                       .server("Anthropic (Claude) didn’t accept the key. Check it in Account."))
        XCTAssertEqual(AIRequest.failure(status: 404, name: "xAI (Grok)", model: "nope"),
                       .server("xAI (Grok) doesn’t know the model “nope”. Change it in Account."))
        XCTAssertEqual(AIRequest.failure(status: 429, name: "Google (Gemini)", model: "g"),
                       .server("Google (Gemini) says the key is out of quota or rate-limited."))
        XCTAssertEqual(AIRequest.failure(status: 500, name: "OpenAI", model: "m"), .server("OpenAI returned 500."))
        XCTAssertEqual(AIRequest.failure(status: 500, name: "OpenAI", model: "m", json: ["error": ["message": "overloaded"]]),
                       .server("overloaded"))
    }

    func testMealEstimateUsesTheStatusSentences() async {
        let config = MealAIConfig(provider: .openai, model: "gpt-4.1-mini", apiKey: "sk-test")
        let session = StatusStub.session
        StatusStub.status = 404
        StatusStub.body = Data("{}".utf8)
        do {
            _ = try await MealAI.estimate("eggs", config: config, session: session)
            XCTFail("expected a 404")
        } catch let error as LogError {
            XCTAssertEqual(error, .server("OpenAI doesn’t know the model “gpt-4.1-mini”. Change it in Account."))
        } catch {
            XCTFail("unexpected \(error)")
        }
        StatusStub.status = 500
        do {
            _ = try await MealAI.estimate("eggs", config: config, session: session)
            XCTFail("expected a 500")
        } catch let error as LogError {
            XCTAssertEqual(error, .server("OpenAI returned 500."))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func json(_ req: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any] ?? [:]
    }
}

/// Answers MealAI.estimate without leaving the test process.
private final class StatusStub: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var body = Data()

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StatusStub.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
