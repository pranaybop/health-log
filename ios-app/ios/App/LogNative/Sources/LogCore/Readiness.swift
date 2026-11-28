import Foundation

/// A daily 0–10 readiness score from Apple Health (`log.daily_health`, `log.health_metrics`
/// and `log.workouts`). Each signal is a robust z-score against the previous 28 days
/// (difference from the median, divided by 1.4826 × MAD, capped at ±3, and flipped so
/// positive means better). The score is 5 + 5/3 × the weighted mean of those z-scores,
/// clamped to 0–10, so 5 is a normal day for you.
///
///   HRV (overnight, higher is better)            24%
///   resting heart rate (lower is better)         20%
///   sleep hours (credited to the wake day)       16%
///   deep + REM minutes                           10%
///   sleeping wrist temperature (lower is better)  8%
///   respiratory rate (lower is better)            7%
///   blood oxygen (higher is better)               5%
///   training load, last 3 days vs those 4 weeks  10%
///
/// A signal with no reading, or without 7 baseline days, is left out and the remaining
/// weights are divided by their sum. Deep + REM counts only when both stages are stored
/// for that night (a stored 0 is a real zero). A day still needs HRV or resting heart
/// rate to score. It tracks the same kinds of signals as a watch readiness score but
/// won't match one.
public enum Readiness {
    public struct Part: Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var value: Double
        public var normal: Double
        /// Positive = better than normal, in spreads (capped ±3).
        public var z: Double
        public var weight: Double
        public var unit: String
    }

    public struct Day: Hashable, Sendable, Identifiable {
        public var key: String
        public var score: Double
        public var parts: [Part]
        /// Days since the last real dose (0 = shot day), when within a week.
        public var daysSinceDose: Int?
        public var calories: Double?
        public var weightTrend: Double?
        public var id: String { key }

        public var band: String {
            switch score {
            case 7...: return "Ready"
            case 4..<7: return "Normal"
            default: return "Take it easier"
            }
        }
    }

    /// Nominal shares. They sum to 1; a missing signal drops out and the rest are scaled.
    static let weights: [String: Double] = [
        "hrv": 0.24, "rhr": 0.20, "sleep": 0.16, "stages": 0.10,
        "temp": 0.08, "resp": 0.07, "spo2": 0.05, "load": 0.10,
    ]

    /// Training load for one day: minutes, weighted up by heart rate when known.
    static func loadByDay(_ d: Dashboard) -> [String: Double] {
        var m: [String: Double] = [:]
        for w in d.workouts {
            guard let t = w.startedDate, let mins = w.durationMin, mins > 0 else { continue }
            let hr = w.avgHr ?? 110
            m[LogTime.dayKey(t), default: 0] += mins * max(0.5, hr / 110)
        }
        return m
    }

    static func robustZ(_ v: Double, base: [Double], higherIsBetter: Bool, minSpread: Double) -> (z: Double, median: Double)? {
        guard base.count >= 7, let med = Analytics.median(base),
              let mad = Analytics.median(base.map { abs($0 - med) }) else { return nil }
        let spread = max(1.4826 * mad, minSpread)
        let z = (v - med) / spread
        return (max(-3, min(3, higherIsBetter ? z : -z)), med)
    }

    /// First finite value of one `log.health_metrics` series, per day.
    private static func metricValues(_ d: Dashboard, _ id: String) -> [String: Double] {
        var m: [String: Double] = [:]
        for p in d.healthMetrics[id] ?? [] where p.value.isFinite && m[p.day] == nil {
            m[p.day] = p.value
        }
        return m
    }

    public static func day(_ key: String, d: Dashboard,
                           health: [String: DailyHealth]? = nil, load: [String: Double]? = nil,
                           trend: [WeightPoint]? = nil) -> Day? {
        var h = health ?? [:]
        if health == nil { for r in d.dailyHealth { h[r.day] = r } }
        let loads = load ?? loadByDay(d)
        let window = (1...28).map { LogTime.shift(key, -$0) }
        var parts: [Part] = []

        func append(_ id: String, _ label: String, _ unit: String, _ v: Double, _ r: (z: Double, median: Double)) {
            parts.append(Part(id: id, label: label, value: v, normal: r.median, z: r.z, weight: weights[id] ?? 0, unit: unit))
        }
        func add(_ id: String, _ label: String, _ unit: String, _ field: KeyPath<DailyHealth, Double?>, up: Bool, minSpread: Double) {
            guard let v = h[key]?[keyPath: field] else { return }
            let base = window.compactMap { h[$0]?[keyPath: field] }
            guard let r = robustZ(v, base: base, higherIsBetter: up, minSpread: minSpread) else { return }
            append(id, label, unit, v, r)
        }
        func addValue(_ id: String, _ label: String, _ unit: String, _ value: Double?, _ base: [Double], up: Bool, minSpread: Double) {
            guard let v = value, let r = robustZ(v, base: base, higherIsBetter: up, minSpread: minSpread) else { return }
            append(id, label, unit, v, r)
        }
        add("hrv", "HRV", "ms", \.hrvMs, up: true, minSpread: 3)
        add("rhr", "Resting HR", "bpm", \.restingHr, up: false, minSpread: 1.5)
        guard !parts.isEmpty else { return nil }
        add("sleep", "Sleep", "h", \.sleepHours, up: true, minSpread: 0.4)

        // Deep + REM, in minutes. Both stages have to be stored; a missing one is not a zero.
        let deep = metricValues(d, "sleep_deep_min")
        let rem = metricValues(d, "sleep_rem_min")
        func restorative(_ day: String) -> Double? {
            guard let a = deep[day], let b = rem[day] else { return nil }
            return a + b
        }
        addValue("stages", "Deep + REM", "min", restorative(key), window.compactMap(restorative), up: true, minSpread: 20)

        let wrist = metricValues(d, "wrist_temp_f")
        addValue("temp", "Wrist temp", "°F", wrist[key], window.compactMap { wrist[$0] }, up: false, minSpread: 0.3)
        let breathing = metricValues(d, "respiratory_rate")
        addValue("resp", "Breathing", "/min", breathing[key], window.compactMap { breathing[$0] }, up: false, minSpread: 0.5)
        let oxygen = metricValues(d, "spo2_avg")
        addValue("spo2", "Blood oxygen", "%", oxygen[key], window.compactMap { oxygen[$0] }, up: true, minSpread: 0.8)

        // Load: average of the 3 days before this one vs the 4 weeks before; more = less ready.
        let acute = (1...3).map { loads[LogTime.shift(key, -$0)] ?? 0 }.reduce(0, +) / 3
        let chronicDays = window.map { loads[$0] ?? 0 }
        let trainedDays = chronicDays.filter { $0 > 0 }.count
        if trainedDays >= 4 {
            let chronic = chronicDays.reduce(0, +) / 28
            // Spread: half the chronic load, so 1.5× usual load reads as one spread worse.
            let z = max(-3, min(3, -(acute - chronic) / max(5, chronic * 0.5)))
            parts.append(Part(id: "load", label: "Training load", value: acute, normal: chronic, z: z, weight: weights["load"]!, unit: "load"))
        }

        let total = parts.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        let zbar = parts.reduce(0) { $0 + $1.z * $1.weight } / total
        let score = max(0, min(10, 5 + zbar * 5 / 3))

        // Context shown next to the score.
        let dayStart = LogTime.noon(key)
        let lastDose = d.doses.filter { $0.counts }.compactMap(\.takenDate).filter { LogTime.dayKey($0) <= key }.max()
        let since = lastDose.map { LogTime.dayDiff(key, LogTime.dayKey($0)) }
        let kcal = d.dailyTotals.first { $0.date == key }?.calories
        let wt = trend.flatMap { Analytics.trend(at: dayStart.addingTimeInterval(6 * 3600), in: $0) }

        return Day(key: key, score: (score * 10).rounded() / 10, parts: parts,
                   daysSinceDose: since.flatMap { $0 <= 7 ? $0 : nil }, calories: kcal, weightTrend: wt)
    }

    /// The one or two signals that moved this score the most, largest |z × weight| first.
    /// A signal counts when it is at least half a spread from normal. An equal contribution
    /// is broken by id, so the same day always produces the same sentence.
    public static func whatMoved(_ day: Day) -> String {
        let ranked = day.parts.filter { abs($0.z) >= 0.5 }.sorted { a, b in
            let aw = abs(a.z * a.weight), bw = abs(b.z * b.weight)
            if aw != bw { return aw > bw }
            return a.id < b.id
        }
        let top = Array(ranked.prefix(2))
        let body: String
        if top.isEmpty {
            body = "Everything used is close to your normal."
        } else if top.count == 1 {
            body = phrase(top[0]) + "."
        } else {
            body = phrase(top[0]) + ", and " + uncapitalized(phrase(top[1])) + "."
        }
        guard let n = day.daysSinceDose, n <= 2 else { return body }
        return body + (n == 0 ? " Shot day." : " Day \(n) after a shot.")
    }

    private static func phrase(_ p: Part) -> String {
        let better = p.z > 0
        switch p.id {
        case "hrv": return better ? "HRV is above your normal" : "HRV is below your normal"
        case "rhr": return better ? "Resting heart rate is lower than usual" : "Resting heart rate is up"
        case "sleep": return better ? "You slept more than usual" : "Sleep was short"
        case "stages": return better ? "Deep and REM sleep are up" : "Deep and REM sleep are down"
        case "temp": return better ? "Wrist temperature is below your normal" : "Wrist temperature is up"
        case "resp": return better ? "Breathing rate is lower than usual" : "Breathing rate is up"
        case "spo2": return better ? "Blood oxygen is above your normal" : "Blood oxygen is below your normal"
        case "load": return better ? "Recent training is lighter than usual" : "Recent training is heavier than usual"
        default: return p.label
        }
    }

    /// Lowercase the first letter, leaving the HRV abbreviation alone.
    private static func uncapitalized(_ s: String) -> String {
        if s.hasPrefix("HRV") { return s }
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// The last `days` days, oldest first, skipping days without HRV or resting HR.
    public static func history(_ d: Dashboard, now: Date, days: Int = 30) -> [Day] {
        var h: [String: DailyHealth] = [:]
        for r in d.dailyHealth { h[r.day] = r }
        let loads = loadByDay(d)
        let sm = Analytics.smoothWeights(d)
        let today = LogTime.today(now)
        return (0..<days).reversed().compactMap { i in
            day(LogTime.shift(today, -i), d: d, health: h, load: loads, trend: sm)
        }
    }
}
