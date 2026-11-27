import Foundation

/// A daily 0–10 readiness score from what Apple Health already syncs (log.daily_health and
/// log.workouts), each signal judged against your own last 4 weeks:
///
///   HRV (overnight, higher is better)      35%
///   resting heart rate (lower is better)   30%
///   sleep hours (credited to the wake day) 25%
///   training load, last 3 days vs 4 weeks  10%
///
/// Each signal becomes a robust z-score (difference from the 28-day median over 1.4826 × MAD,
/// capped at ±3, flipped so positive means better). The score is 5 + 5/3 × the weighted mean,
/// clamped to 0–10, so 5 is a normal day for you. Signals without 7 baseline days are left
/// out and the weights renormalized; a day needs HRV or resting HR to get a score at all.
/// It tracks the same signals as watch "readiness" scores but won't match any of them.
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

    static let weights: [String: Double] = ["hrv": 0.35, "rhr": 0.30, "sleep": 0.25, "load": 0.10]

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

    public static func day(_ key: String, d: Dashboard,
                           health: [String: DailyHealth]? = nil, load: [String: Double]? = nil,
                           trend: [WeightPoint]? = nil) -> Day? {
        var h = health ?? [:]
        if health == nil { for r in d.dailyHealth { h[r.day] = r } }
        let loads = load ?? loadByDay(d)
        let window = (1...28).map { LogTime.shift(key, -$0) }
        var parts: [Part] = []

        func add(_ id: String, _ label: String, _ unit: String, _ field: KeyPath<DailyHealth, Double?>, up: Bool, minSpread: Double) {
            guard let v = h[key]?[keyPath: field] else { return }
            let base = window.compactMap { h[$0]?[keyPath: field] }
            guard let r = robustZ(v, base: base, higherIsBetter: up, minSpread: minSpread) else { return }
            parts.append(Part(id: id, label: label, value: v, normal: r.median, z: r.z, weight: weights[id] ?? 0, unit: unit))
        }
        add("hrv", "HRV", "ms", \.hrvMs, up: true, minSpread: 3)
        add("rhr", "Resting HR", "bpm", \.restingHr, up: false, minSpread: 1.5)
        guard !parts.isEmpty else { return nil }
        add("sleep", "Sleep", "h", \.sleepHours, up: true, minSpread: 0.4)

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
