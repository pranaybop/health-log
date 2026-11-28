import Foundation

// "Ask your data": a plain-text snapshot of the log for a language model, and the call that
// sends it with the AI key saved under Account (OpenAI, Anthropic, Google or xAI). The free,
// no-key path is Apple Intelligence on the phone (LogUI/Shared/AskScreen.swift); its context is
// small, so it gets the `.compact` snapshot.

public enum DataDigest {
    /// compact: 2 weeks (Apple Intelligence's small context); full: 90 days with meals (cloud).
    public enum Size: Sendable { case compact, full }

    static func f(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    /// The log as compact text, newest first. `compact` fits Apple Intelligence's small context
    /// (about 2 weeks); `full` is ~90 days for Claude or Grok.
    public static func make(_ d: Dashboard, now: Date = Date(), size: Size = .full) -> String {
        let full = size != .compact
        let days = size == .full ? 90 : 14
        let today = LogTime.today(now)
        let from = LogTime.shift(today, -(days - 1))
        var out: [String] = []
        out.append("Health log snapshot. Today is \(today) (\(LogTime.calendar.timeZone.identifier)). Units: lb, kcal, g, minutes, bpm, ms.")

        if let p = d.profile {
            out.append("Profile: start \(f(p.startWeightLb, 1)) lb, goal \(f(p.goalWeightLb, 1)) lb, height \(f(p.heightIn)) in.")
        }
        let t = Analytics.Trends.targets(d)
        out.append("Daily targets: calories \(f(t.calories)), protein \(f(t.protein)) g.")

        let sm = Analytics.smoothWeights(d)
        if let last = sm.last {
            var line = "Weight: trend \(f(last.trend, 1)) lb, last weigh-in \(f(last.lb, 1)) lb on \(last.day)."
            if let pr = WeightProgress.make(sm, startLb: d.profile?.startWeightLb, goalLb: d.profile?.goalWeightLb, since: Analytics.Trends.firstGlp1At(d), now: now) {
                line += " Pace (trend, 4 wk) \(f(pr.weekly, 2)) lb/week. Lost \(f(pr.done, 1)) lb since start."
                if let toGo = pr.toGo { line += " \(f(toGo, 1)) lb to goal." }
                if let eta = pr.goalETA { line += " Goal around \(LogTime.dayKey(eta)) at this pace." }
                let ch = pr.changes.map { "\($0.label) \(f($0.delta, 1))" }.joined(separator: ", ")
                line += " Trend change: \(ch)."
            }
            out.append(line)
        }

        // Medication.
        let protos = d.protocols.map { p in
            "\(p.compound ?? "?") \(p.status ?? "") \(f(p.typicalDoseMg, 2)) mg \(p.frequency ?? ""), started \(p.startedOn ?? "?"), half-life \(f(p.halfLifeHours)) h"
        }
        if !protos.isEmpty { out.append("Medication protocol: " + protos.joined(separator: "; ") + ".") }
        let doses = d.doses.filter { ($0.takenAt ?? "") >= from }.sorted { ($0.takenAt ?? "") > ($1.takenAt ?? "") }
        if !doses.isEmpty {
            out.append("Doses (date|compound|mg|site|skipped):")
            for x in doses.prefix(full ? 30 : 4) {
                out.append("\(String((x.takenAt ?? "").prefix(10)))|\(x.compound ?? "")|\(f(x.doseMg, 2))|\(x.site ?? "")|\(x.skipped == true ? "yes" : "")")
            }
        }
        if full {
            let next = d.dosePlan.filter { $0.plannedOn >= today }.prefix(4)
            if !next.isEmpty {
                out.append("Next planned doses: " + next.map { "\($0.plannedOn) \($0.compound ?? "") \(f($0.doseMg, 2)) mg" }.joined(separator: ", ") + ".")
            }
        }

        // One row a day.
        var weightByDay: [String: Double] = [:]
        for w in sm { weightByDay[w.day] = w.lb }
        var trendByDay: [String: Double] = [:]
        for w in sm { trendByDay[w.day] = w.trend }
        var food: [String: DailyTotal] = [:]
        for x in d.dailyTotals { food[x.date] = x }
        var health: [String: DailyHealth] = [:]
        for x in d.dailyHealth { health[x.day] = x }
        var checks: [String: Checkin] = [:]
        for x in d.checkins { checks[x.day] = x }
        var thoughts: [String: Int] = [:]
        for x in d.foodThoughts { if let t = x.thoughtDate { thoughts[LogTime.dayKey(t), default: 0] += 1 } }

        out.append("Daily (day|weight|trend|kcal|protein|carbs|fat|steps|active_kcal|exercise_min|sleep_h|resting_hr|hrv|mood|food_noise|energy|food_thoughts). Blank = not logged:")
        var key = today
        for _ in 0..<days {
            let fd = food[key], h = health[key], c = checks[key]
            let cols = [key, f(weightByDay[key], 1), f(trendByDay[key], 1), f(fd?.calories), f(fd?.proteinG), f(fd?.carbsG), f(fd?.fatG),
                        f(h?.steps ?? c?.steps), f(h?.activeKcal ?? c?.activeCalories), f(h?.exerciseMin ?? c?.exerciseMinutes),
                        f(h?.sleepHours ?? c?.sleepHours, 1), f(h?.restingHr ?? c?.restingHr), f(h?.hrvMs),
                        f(c?.mood), f(c?.foodNoise), f(c?.energy), thoughts[key].map(String.init) ?? ""]
            if cols.dropFirst().contains(where: { !$0.isEmpty }) { out.append(cols.joined(separator: "|")) }
            key = LogTime.shift(key, -1)
        }

        let ready = Readiness.history(d, now: now, days: full ? 30 : 7)
        if !ready.isEmpty {
            out.append("Readiness 0-10 (5 = their normal; from HRV, resting HR, sleep, training load vs their last 4 weeks): "
                       + ready.reversed().map { "\($0.key) \(f($0.score, 1))" }.joined(separator: ", ") + ".")
        }
        let effects = d.sideEffects.filter { ($0.recordedOn ?? "") >= from }
        if !effects.isEmpty {
            out.append("Side effects: " + effects.prefix(full ? 40 : 6).map { "\($0.recordedOn ?? "") \($0.effect ?? "") \(f($0.severity))/10" }.joined(separator: "; ") + ".")
        }
        let notes = d.checkins.filter { $0.day >= from && !($0.notes ?? "").isEmpty }
        if full && !notes.isEmpty {
            out.append("Check-in notes: " + notes.prefix(20).map { "\($0.day): \($0.notes ?? "")" }.joined(separator: " | "))
        }

        let workouts = d.workouts.filter { ($0.startedAt ?? "") >= from }.sorted { ($0.startedAt ?? "") > ($1.startedAt ?? "") }
        if !workouts.isEmpty {
            out.append("Workouts (day|activity|min|mi|avg_hr):")
            for w in workouts.prefix(full ? 40 : 5) {
                out.append("\(String((w.startedAt ?? "").prefix(10)))|\(w.activity ?? "")|\(f(w.durationMin))|\(f(w.distanceMi, 2))|\(f(w.avgHr))")
            }
        }

        if full {
            let weeks = d.weeklySummary.suffix(16)
            if !weeks.isEmpty {
                out.append("Weekly (week|avg_kcal|avg_protein|days_logged|avg_weight):")
                for w in weeks.reversed() {
                    out.append("\(w.week)|\(f(w.avgDailyCalories))|\(f(w.avgProteinG))|\(f(w.daysLogged))|\(f(w.avgWeightLb, 1))")
                }
            }
            let mealFrom = LogTime.shift(today, -2)
            let meals = d.meals.filter { $0.eatenDate.map { LogTime.dayKey($0) >= mealFrom } ?? false }
            if size == .full && !meals.isEmpty {
                out.append("Meals, last 3 days (time|item|kcal|protein):")
                for m in meals.sorted(by: { ($0.eatenAt ?? "") > ($1.eatenAt ?? "") }).prefix(40) {
                    out.append("\(m.eatenAt ?? "")|\(m.item ?? "")|\(f(m.calories))|\(f(m.proteinG))")
                }
            }
            let body = d.measurements.filter { ($0.measuredAt ?? "") >= from }.sorted { ($0.measuredAt ?? "") > ($1.measuredAt ?? "") }
            if !body.isEmpty {
                out.append("Measurements: " + body.prefix(20).map { "\(String(($0.measuredAt ?? "").prefix(10))) \($0.metric ?? "") \(f($0.value, 1)) \($0.unit ?? "")" }.joined(separator: "; ") + ".")
            }
        }
        return out.joined(separator: "\n")
    }

    /// What the model is told before the snapshot.
    public static let instructions = """
    You answer questions about the user's own health log: weight, food, medication (GLP-1s \
    and peptides), Apple Health activity, sleep and heart data, and daily check-ins. \
    Use only the snapshot below; if it doesn't hold the answer, say what's missing. Quote the \
    actual numbers and dates you used, look for patterns across days, and keep answers short and \
    plain. Weight changes should use the trend, not single weigh-ins. You are not a doctor: for \
    dosing or symptoms, describe what the data shows and suggest asking their prescriber.
    """
}

// MARK: - With the person's own AI key

public struct AskTurn: Hashable, Sendable, Identifiable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public var id = UUID()
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

/// Ask with the AI key saved under Account (the same one meal logging uses), straight from the
/// phone to that company. Nothing goes through the log's server. With a dashboard, the model can
/// call AskTools to look up any date range; each call runs here on the phone.
public enum AskCloud {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()

    /// Rounds of tool calls before giving up (each round can call several tools).
    static let maxRounds = 6

    public static func send(_ config: MealAIConfig, system: String, turns: [AskTurn], dashboard: Dashboard? = nil,
                            now: Date = Date()) async throws -> String {
        let name = config.provider.name
        var messages = initialMessages(config.provider, turns: turns)
        for _ in 0..<maxRounds {
            let req = try request(config, system: system, messages: messages, tools: dashboard != nil)
            let json = try await post(req, name: name, model: config.model)
            switch config.provider {
            case .anthropic:
                if json["stop_reason"] as? String == "refusal" {
                    return "Claude declined to answer that one. Try rephrasing the question."
                }
                let content = json["content"] as? [[String: Any]] ?? []
                let calls = content.filter { $0["type"] as? String == "tool_use" }
                if let d = dashboard, !calls.isEmpty {
                    messages.append(["role": "assistant", "content": content])
                    messages.append(["role": "user", "content": calls.map { c -> [String: Any] in
                        ["type": "tool_result", "tool_use_id": c["id"] as? String ?? "",
                         "content": AskTools.run(c["name"] as? String ?? "", arguments: c["input"] as? [String: Any] ?? [:], d: d, now: now)]
                    }])
                    continue
                }
                return try text(content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(), name)
            case .openai, .xai:
                let message = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                if let d = dashboard, !calls.isEmpty {
                    messages.append(message)
                    for c in calls {
                        let fn = c["function"] as? [String: Any] ?? [:]
                        let argText = fn["arguments"] as? String ?? "{}"
                        let args = (try? JSONSerialization.jsonObject(with: Data(argText.utf8))) as? [String: Any] ?? [:]
                        messages.append(["role": "tool", "tool_call_id": c["id"] as? String ?? "",
                                         "content": AskTools.run(fn["name"] as? String ?? "", arguments: args, d: d, now: now)])
                    }
                    continue
                }
                return try text(message["content"] as? String ?? "", name)
            case .google:
                let content = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]) ?? [:]
                let parts = content["parts"] as? [[String: Any]] ?? []
                let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
                if let d = dashboard, !calls.isEmpty {
                    messages.append(content)
                    messages.append(["role": "user", "parts": calls.map { c -> [String: Any] in
                        let fname = c["name"] as? String ?? ""
                        let result = AskTools.run(fname, arguments: c["args"] as? [String: Any] ?? [:], d: d, now: now)
                        let response: [String: Any] = ["name": fname, "response": ["result": result]]
                        return ["functionResponse": response]
                    }])
                    continue
                }
                return try text(parts.compactMap { $0["text"] as? String }.joined(), name)
            }
        }
        throw LogError.server("\(name) kept looking things up without answering. Try a narrower question.")
    }

    static func text(_ s: String, _ name: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw LogError.server("Couldn’t read \(name)’s answer.") }
        return t
    }

    static func initialMessages(_ provider: MealAIProvider, turns: [AskTurn]) -> [[String: Any]] {
        switch provider {
        case .google:
            return turns.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] }
        default:
            return turns.map { ["role": $0.role.rawValue, "content": $0.text] }
        }
    }

    static func post(_ req: URLRequest, name: String, model: String) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw LogError.network("Couldn’t reach \(name). Check your connection.") }
        guard let http = response as? HTTPURLResponse else { throw LogError.network("No response from \(name).") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw AIRequest.failure(status: http.statusCode, name: name, model: model, json: json)
        }
        return json
    }

    static func request(_ config: MealAIConfig, system: String, messages: [[String: Any]], tools: Bool) throws -> URLRequest {
        let model = AIRequest.model(config)
        var body: [String: Any]
        switch config.provider {
        case .openai, .xai:
            let systemMessage: [String: Any] = ["role": "system", "content": system]
            body = ["model": model, "messages": [systemMessage] + messages]
            if tools { body["tools"] = AskTools.functionSchemas }
        case .anthropic:
            body = ["model": model, "max_tokens": 16000, "system": system, "messages": messages]
            if tools { body["tools"] = AskTools.anthropicSchemas }
        case .google:
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": messages]
            if tools { body["tools"] = AskTools.googleSchemas }
        }
        return try AIRequest.make(config, model: model, timeout: 120, body: body)
    }
}
