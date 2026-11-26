import Foundation
import Security

// "Ask your data": a plain-text snapshot of the log for a language model, the key store for
// people who bring their own API key, and the two cloud calls (Claude and Grok). The free,
// no-key path is Apple Intelligence on the phone (LogUI/Shared/AskScreen.swift); its context is
// small, so it gets the `.compact` snapshot.

public enum DataDigest {
    public enum Size: Sendable { case compact, full }

    static func f(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    /// The log as compact text, newest first. `compact` fits Apple Intelligence's small context
    /// (about 2 weeks); `full` is ~90 days for Claude or Grok.
    public static func make(_ d: Dashboard, now: Date = Date(), size: Size = .full) -> String {
        let full = size == .full
        let days = full ? 90 : 14
        let today = LogTime.today(now)
        let from = LogTime.shift(today, -(days - 1))
        var out: [String] = []
        out.append("Health log snapshot. Today is \(today) (America/Chicago). Units: lb, kcal, g, minutes, bpm, ms.")

        if let p = d.profile {
            out.append("Profile: start \(f(p.startWeightLb, 1)) lb, goal \(f(p.goalWeightLb, 1)) lb, height \(f(p.heightIn)) in.")
        }
        let t = TrendsCalc.targets(d)
        out.append("Daily targets: calories \(f(t.calories)), protein \(f(t.protein)) g.")

        let sm = Analytics.smoothWeights(d)
        if let last = sm.last {
            var line = "Weight: trend \(f(last.trend, 1)) lb, last weigh-in \(f(last.lb, 1)) lb on \(last.day)."
            if let pr = WeightProgress.make(sm, startLb: d.profile?.startWeightLb, goalLb: d.profile?.goalWeightLb, now: now) {
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
            if !meals.isEmpty {
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
    You answer questions about the user's own health log: weight, food, GLP-1 medication \
    (tirzepatide, retatrutide), Apple Health activity, sleep and heart data, and daily check-ins. \
    Use only the snapshot below; if it doesn't hold the answer, say what's missing. Quote the \
    actual numbers and dates you used, look for patterns across days, and keep answers short and \
    plain. Weight changes should use the trend, not single weigh-ins. You are not a doctor: for \
    dosing or symptoms, describe what the data shows and suggest asking their prescriber.
    """
}

// MARK: - Bring your own key

public enum AskProvider: String, CaseIterable, Identifiable, Sendable {
    case onDevice, claude, grok
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .onDevice: return "On this iPhone"
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }

    public var defaultModel: String {
        switch self {
        case .onDevice: return ""
        case .claude: return "claude-opus-5-5"
        case .grok: return "grok-4"
        }
    }

    public var keyHint: String {
        switch self {
        case .onDevice: return ""
        case .claude: return "Anthropic API key (console.anthropic.com)"
        case .grok: return "xAI API key (console.x.ai)"
        }
    }
}

/// API keys in the Keychain, this device only. Never logged, never sent to the log's server.
public enum AskKeyStore {
    private static let service = "com.pranaybop.log.ask"

    private static func query(_ p: AskProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: p.rawValue]
    }

    public static func read(_ p: AskProvider) -> String? {
        var q = query(p)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    public static func write(_ p: AskProvider, _ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { clear(p); return }
        let attrs: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        if SecItemUpdate(query(p) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query(p)
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func clear(_ p: AskProvider) { SecItemDelete(query(p) as CFDictionary) }
}

public struct AskTurn: Hashable, Sendable, Identifiable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public var id = UUID()
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

/// The cloud calls, straight from the phone to the provider with the user's own key.
public enum AskCloud {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()

    public static func send(_ provider: AskProvider, key: String, model: String, system: String, turns: [AskTurn]) async throws -> String {
        switch provider {
        case .claude: return try await claude(key: key, model: model, system: system, turns: turns)
        case .grok: return try await grok(key: key, model: model, system: system, turns: turns)
        case .onDevice: throw LogError.server("On-device answers don't use the network.")
        }
    }

    static func claude(key: String, model: String, system: String, turns: [AskTurn]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // If a safety check declines on the chosen model, the API retries on a fallback model.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await post(req, who: "Claude")
        if (json["stop_reason"] as? String) == "refusal" {
            return "Claude declined to answer that one. Try rephrasing the question."
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LogError.server("Claude sent back an empty answer.") }
        return text
    }

    static func grok(key: String, model: String, system: String, turns: [AskTurn]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += turns.map { ["role": $0.role.rawValue, "content": $0.text] }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages])
        let json = try await post(req, who: "Grok")
        let choices = json["choices"] as? [[String: Any]] ?? []
        let text = (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !text.isEmpty else { throw LogError.server("Grok sent back an empty answer.") }
        return text
    }

    static func post(_ req: URLRequest, who: String) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw LogError.network("Couldn’t reach \(who). Check your connection.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse else { throw LogError.network("No response from \(who).") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw LogError.server("\(who) rejected the API key.") }
            let err = json["error"]
            let msg = (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "\(who) returned \(http.statusCode)."
            throw LogError.server(msg)
        }
        return json
    }
}
