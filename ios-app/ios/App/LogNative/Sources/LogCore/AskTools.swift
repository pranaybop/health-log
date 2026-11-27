import Foundation

/// Tools Ask's model can call to look things up in the log, so the prompt can stay short (two
/// weeks of overview) while questions can still reach any date. Used with your own AI key
/// (each provider's tool-calling format). Every tool returns plain text tables, newest first.
public enum AskTools {
    public struct Spec: @unchecked Sendable {
        public var name: String
        public var description: String
        /// JSON Schema for the arguments.
        public var parameters: [String: any Sendable]
    }

    static let range: [String: any Sendable] = [
        "type": "object",
        "properties": [
            "start": ["type": "string", "description": "First day, YYYY-MM-DD"] as [String: any Sendable],
            "end": ["type": "string", "description": "Last day, YYYY-MM-DD (inclusive)"] as [String: any Sendable],
        ] as [String: any Sendable],
        "required": ["start", "end"],
    ]

    public static let specs: [Spec] = [
        Spec(name: "get_days",
             description: "One row per day for a date range (at most 120 days): weight, trend, calories, protein, carbs, fat, steps, active calories, exercise minutes, sleep hours, resting heart rate, HRV, mood, food noise, energy, food thoughts and readiness (0-10).",
             parameters: range),
        Spec(name: "get_doses",
             description: "Medication doses (date, compound, mg, site, skipped) and side effects (date, effect, severity 1-10) in a date range.",
             parameters: range),
        Spec(name: "get_meals",
             description: "Meals logged in a date range (at most 14 days): time, item, calories, protein, carbs, fat.",
             parameters: range),
        Spec(name: "get_workouts",
             description: "Workouts in a date range: day, activity, minutes, miles, average heart rate.",
             parameters: range),
        Spec(name: "get_weekly",
             description: "Weekly averages (Monday weeks) in a date range: calories, protein, days logged, average weight.",
             parameters: range),
        Spec(name: "get_metric",
             description: "Daily values of one Apple Health metric in a date range. Metrics: heart_rate_avg, respiratory_rate, spo2_avg, bp_systolic, bp_diastolic, glucose_avg, wrist_temp_f, sleep_in_bed_h, sleep_deep_min, sleep_rem_min, sleep_core_min, basal_kcal, total_kcal, water_oz, flights, mindful_min, vo2max.",
             parameters: [
                "type": "object",
                "properties": [
                    "metric": ["type": "string", "description": "Metric name from the list"] as [String: any Sendable],
                    "start": ["type": "string", "description": "First day, YYYY-MM-DD"] as [String: any Sendable],
                    "end": ["type": "string", "description": "Last day, YYYY-MM-DD (inclusive)"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["metric", "start", "end"],
             ]),
    ]

    /// The line added to the system prompt when tools are on.
    public static let hint = """
    The snapshot covers about two weeks. For anything older or more detailed, call the tools \
    (dates as YYYY-MM-DD) instead of guessing; call more than one if the question needs it.
    """

    // MARK: Provider formats

    /// OpenAI / xAI: {"type": "function", "function": {name, description, parameters}}
    public static var functionSchemas: [[String: any Sendable]] {
        specs.map { s in
            ["type": "function",
             "function": ["name": s.name, "description": s.description, "parameters": s.parameters] as [String: any Sendable]]
        }
    }

    /// Anthropic: {name, description, input_schema}
    public static var anthropicSchemas: [[String: any Sendable]] {
        specs.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
    }

    /// Google: one {functionDeclarations: [...]} entry.
    public static var googleSchemas: [[String: any Sendable]] {
        [["functionDeclarations": specs.map { s -> [String: any Sendable] in
            ["name": s.name, "description": s.description, "parameters": s.parameters]
        }]]
    }

    // MARK: Running a tool

    static func f(_ v: Double?, _ digits: Int = 0) -> String { DataDigest.f(v, digits) }

    static func day(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let t = String(s.prefix(10))
        guard t.count == 10, LogTime.parse(t) != nil else { return nil }
        return t
    }

    /// Runs a tool and returns its text result (an explanation when the arguments are wrong).
    public static func run(_ name: String, arguments: [String: Any], d: Dashboard, now: Date = Date()) -> String {
        let today = LogTime.today(now)
        guard var start = day(arguments["start"]), var end = day(arguments["end"]) else {
            return "Give start and end as YYYY-MM-DD."
        }
        if start > end { swap(&start, &end) }
        if end > today { end = today }
        switch name {
        case "get_days": return days(d, start, end)
        case "get_doses": return doses(d, start, end)
        case "get_meals": return meals(d, start, end)
        case "get_workouts": return workouts(d, start, end)
        case "get_weekly": return weekly(d, start, end)
        case "get_metric": return metric(d, arguments["metric"] as? String ?? "", start, end)
        default: return "There's no tool called \(name)."
        }
    }

    static func days(_ d: Dashboard, _ start: String, _ endKey: String) -> String {
        var from = start
        if LogTime.dayDiff(endKey, from) > 119 { from = LogTime.shift(endKey, -119) }
        let sm = Analytics.smoothWeights(d)
        var weight: [String: Double] = [:], trend: [String: Double] = [:]
        for w in sm { weight[w.day] = w.lb; trend[w.day] = w.trend }
        var food: [String: DailyTotal] = [:]
        for x in d.dailyTotals { food[x.date] = x }
        var health: [String: DailyHealth] = [:]
        for x in d.dailyHealth { health[x.day] = x }
        var checks: [String: Checkin] = [:]
        for x in d.checkins { checks[x.day] = x }
        var thoughts: [String: Int] = [:]
        for x in d.foodThoughts { if let t = x.thoughtDate { thoughts[LogTime.dayKey(t), default: 0] += 1 } }
        var ready: [String: Double] = [:]
        for r in Readiness.history(d, now: LogTime.noon(endKey), days: LogTime.dayDiff(endKey, from) + 1) { ready[r.key] = r.score }

        var out = ["day|weight|trend|kcal|protein|carbs|fat|steps|active_kcal|exercise_min|sleep_h|resting_hr|hrv|mood|food_noise|energy|food_thoughts|readiness"]
        var key = endKey
        while key >= from {
            let fd = food[key], h = health[key], c = checks[key]
            let cols = [key, f(weight[key], 1), f(trend[key], 1), f(fd?.calories), f(fd?.proteinG), f(fd?.carbsG), f(fd?.fatG),
                        f(h?.steps ?? c?.steps), f(h?.activeKcal ?? c?.activeCalories), f(h?.exerciseMin ?? c?.exerciseMinutes),
                        f(h?.sleepHours ?? c?.sleepHours, 1), f(h?.restingHr ?? c?.restingHr), f(h?.hrvMs),
                        f(c?.mood), f(c?.foodNoise), f(c?.energy), thoughts[key].map(String.init) ?? "", f(ready[key], 1)]
            if cols.dropFirst().contains(where: { !$0.isEmpty }) { out.append(cols.joined(separator: "|")) }
            key = LogTime.shift(key, -1)
        }
        if out.count == 1 { return "Nothing logged from \(from) to \(endKey)." }
        if from != start { out.insert("(Only the last 120 days of the range.)", at: 0) }
        return out.joined(separator: "\n")
    }

    static func inRange(_ ts: String?, _ start: String, _ end: String) -> Bool {
        guard let ts, let date = LogTime.parse(ts) else { return false }
        let k = LogTime.dayKey(date)
        return k >= start && k <= end
    }

    static func doses(_ d: Dashboard, _ start: String, _ end: String) -> String {
        var out: [String] = []
        let ds = d.doses.filter { inRange($0.takenAt, start, end) }.sorted { ($0.takenAt ?? "") > ($1.takenAt ?? "") }
        if !ds.isEmpty {
            out.append("doses: day|compound|mg|site|skipped")
            for x in ds.prefix(80) {
                out.append("\(x.takenDate.map(LogTime.dayKey) ?? "")|\(x.compound ?? "")|\(f(x.doseMg, 2))|\(x.site ?? "")|\(x.skipped == true ? "yes" : "")")
            }
        }
        let fx = d.sideEffects.filter { ($0.recordedOn ?? "") >= start && ($0.recordedOn ?? "") <= end }
        if !fx.isEmpty {
            out.append("side effects: day|effect|severity")
            for x in fx.sorted(by: { ($0.recordedOn ?? "") > ($1.recordedOn ?? "") }).prefix(80) {
                out.append("\(x.recordedOn ?? "")|\(x.effect ?? "")|\(f(x.severity))")
            }
        }
        return out.isEmpty ? "No doses or side effects from \(start) to \(end)." : out.joined(separator: "\n")
    }

    static func meals(_ d: Dashboard, _ start: String, _ endKey: String) -> String {
        var from = start
        if LogTime.dayDiff(endKey, from) > 13 { from = LogTime.shift(endKey, -13) }
        let ms = d.meals.filter { inRange($0.eatenAt, from, endKey) }.sorted { ($0.eatenAt ?? "") > ($1.eatenAt ?? "") }
        guard !ms.isEmpty else { return "No meals logged from \(from) to \(endKey)." }
        var out = ["time|item|kcal|protein|carbs|fat"]
        for m in ms.prefix(120) {
            let t = m.eatenDate.map { "\(LogTime.dayKey($0)) \(LogTime.time($0))" } ?? (m.eatenAt ?? "")
            out.append("\(t)|\(m.item ?? "")|\(f(m.calories))|\(f(m.proteinG))|\(f(m.carbsG))|\(f(m.fatG))")
        }
        if from != start { out.insert("(Only the last 14 days of the range.)", at: 0) }
        return out.joined(separator: "\n")
    }

    static func workouts(_ d: Dashboard, _ start: String, _ end: String) -> String {
        let ws = d.workouts.filter { inRange($0.startedAt, start, end) }.sorted { ($0.startedAt ?? "") > ($1.startedAt ?? "") }
        guard !ws.isEmpty else { return "No workouts from \(start) to \(end)." }
        var out = ["day|activity|min|mi|avg_hr"]
        for w in ws.prefix(100) {
            out.append("\(w.startedDate.map(LogTime.dayKey) ?? "")|\(w.activity ?? "")|\(f(w.durationMin))|\(f(w.distanceMi, 2))|\(f(w.avgHr))")
        }
        return out.joined(separator: "\n")
    }

    static func weekly(_ d: Dashboard, _ start: String, _ end: String) -> String {
        let ws = d.weeklySummary.filter { String($0.week.prefix(10)) >= LogTime.monday(start) && String($0.week.prefix(10)) <= end }
        guard !ws.isEmpty else { return "No weekly summaries from \(start) to \(end)." }
        var out = ["week|avg_kcal|avg_protein|days_logged|avg_weight"]
        for w in ws.reversed() {
            out.append("\(String(w.week.prefix(10)))|\(f(w.avgDailyCalories))|\(f(w.avgProteinG))|\(f(w.daysLogged))|\(f(w.avgWeightLb, 1))")
        }
        return out.joined(separator: "\n")
    }

    static func metric(_ d: Dashboard, _ id: String, _ start: String, _ end: String) -> String {
        let name = id.trimmingCharacters(in: .whitespaces).lowercased()
        let pts = Analytics.Trends.metricPoints(d, name).filter { $0.key >= start && $0.key <= end }
        guard !pts.isEmpty else { return "No \(name) values from \(start) to \(end)." }
        return (["day|\(name)"] + pts.reversed().map { "\($0.key)|\(f($0.value, 1))" }).joined(separator: "\n")
    }
}
