import Foundation

// Calculations behind the Today tab, ported from the original web app (removed Nov 2026) (analytics.js, focus.js, signals.js,
// insights.js and app.js). Numbers only: the wording lives with the Today screen in LogUI.
// TodayTests checks them against the web functions run on the made-up fixture.

/// Straight-line pace through the last weeks of weigh-ins (web recentPace).
public struct WeightPace: Hashable, Sendable {
    /// lb per week (negative = losing).
    public var weekly: Double
    /// The fitted line's value at the last weigh-in.
    public var fittedNow: Double
    /// Days with a weigh-in in the window.
    public var count: Int
}

/// Start, goal and current weight (web journeyStats).
public struct WeightJourney: Hashable, Sendable {
    public var current: WeightPoint
    public var startLb: Double
    public var goalLb: Double?
    public var sinceTirz: WeightPoint
    /// current - start (negative = down).
    public var changeStart: Double { current.lb - startLb }
}

/// Is the weight flat over the last 3 weeks? (web stallCheck)
public struct StallResult: Hashable, Sendable {
    public var stalled: Bool
    public var ready: Bool
    public var weekly: Double?
    public var change: Double?
    public var fromLb: Double?
    public var toLb: Double?
}

/// One night's sleep stages in minutes (log.health_metrics sleep_*_min).
public struct SleepStages: Hashable, Sendable {
    public var core: Double?
    public var deep: Double?
    public var rem: Double?
    public var awake: Double?
    public var total: Double { (core ?? 0) + (deep ?? 0) + (rem ?? 0) + (awake ?? 0) }
}

/// A recovery signal checked against its own normal (web NORMAL_SIGNALS).
public struct SignalSpec: Hashable, Sendable {
    public var id: String
    public var label: String
    /// From log.daily_health (else log.health_metrics).
    public var daily: Bool
    /// Off when it goes up (else when it goes down).
    public var up: Bool
    public var unit: String
    public var digits: Int
    var fixedFloor: Double
    /// The smallest change that counts as off: 4 bpm, 20% of HRV, 1.5 breaths a minute, 0.9 °F.
    public func floor(median: Double) -> Double { id == "hrv_ms" ? 0.2 * median : fixedFloor }
}

public struct SignalCheck: Hashable, Sendable {
    public var spec: SignalSpec
    public var value: Double
    public var median: Double
    public var diff: Double
    public var off: Bool
}

public struct ProteinStreak: Hashable, Sendable {
    public var target: Double
    public var streak: Int
    public var remaining: Double
    public var hitToday: Bool
    public var todayProtein: Double?
}

extension Analytics {

    // MARK: Weight

    /// The latest weigh-in on each Central day, oldest first (web dailyWeight).
    public static func dailyWeight(_ points: [WeightPoint]) -> [WeightPoint] {
        var byDay: [String: WeightPoint] = [:]
        for p in points { byDay[p.day] = p }
        return byDay.values.sorted { $0.at < $1.at }
    }

    /// Least-squares line through (x, y) points.
    public static func linearFit(_ points: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double)? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let mx = points.reduce(0.0) { $0 + $1.x } / n
        let my = points.reduce(0.0) { $0 + $1.y } / n
        var num = 0.0
        var den = 0.0
        for p in points {
            num += (p.x - mx) * (p.y - my)
            den += (p.x - mx) * (p.x - mx)
        }
        guard den != 0 else { return nil }
        let slope = num / den
        return (slope, my - slope * mx)
    }

    /// Straight-line pace through the last `days` days of weigh-ins, one per day. Needs 4 days
    /// spanning a week.
    public static func recentPace(_ points: [WeightPoint], days: Double = 28) -> WeightPace? {
        guard let last = points.last else { return nil }
        let from = last.at.addingTimeInterval(-days * 86400)
        let daily = dailyWeight(points.filter { $0.at >= from })
        guard daily.count >= 4, let first = daily.first, let end = daily.last else { return nil }
        let span = end.at.timeIntervalSince(first.at) / 86400
        guard span >= 7 else { return nil }
        let xy: [(x: Double, y: Double)] = daily.map { (x: $0.at.timeIntervalSince(first.at) / 86400, y: $0.lb) }
        guard let fit = linearFit(xy) else { return nil }
        return WeightPace(weekly: fit.slope * 7, fittedNow: fit.intercept + fit.slope * span, count: daily.count)
    }

    /// Start (profile, else the first weigh-in), goal (profile) and the latest weigh-in.
    public static func journey(_ d: Dashboard, points: [WeightPoint]? = nil) -> WeightJourney? {
        let pts = points ?? smoothWeights(d)
        guard let current = pts.last, let first = pts.first else { return nil }
        let start = d.profile?.startWeightLb ?? first.lb
        let since = pts.first { $0.at >= LogTime.tirzStart } ?? first
        return WeightJourney(current: current, startLb: start, goalLb: d.profile?.goalWeightLb, sinceTirz: since)
    }

    /// Loss as a share of body weight per week, from the 4-week fit. Fast is over 1% a week.
    public static func lossRate(_ points: [WeightPoint]) -> (weekly: Double, pct: Double, fast: Bool)? {
        guard let cur = points.last, let rp = recentPace(points) else { return nil }
        let pct = (-rp.weekly / cur.lb) * 100
        return (rp.weekly, pct, pct > 1)
    }

    /// Flat for 3 weeks: under 0.4 lb a week and under 2 lb overall, from at least 4 weigh-in days
    /// in the last 21 (and 6 in the last 40).
    public static func stallCheck(_ points: [WeightPoint], now: Date = Date()) -> StallResult {
        let daily = dailyWeight(points.filter { $0.at >= now.addingTimeInterval(-40 * 86400) })
        guard daily.count >= 6 else { return StallResult(stalled: false, ready: false) }
        let win = daily.filter { $0.at >= now.addingTimeInterval(-21 * 86400) }
        guard win.count >= 4, let a = win.first, let b = win.last else { return StallResult(stalled: false, ready: false) }
        let xy: [(x: Double, y: Double)] = win.map { (x: $0.at.timeIntervalSince(a.at) / 86400, y: $0.lb) }
        let change = b.lb - a.lb
        let weekly = linearFit(xy).map { $0.slope * 7 } ?? change / 3
        return StallResult(stalled: abs(weekly) < 0.4 && abs(change) < 2, ready: true, weekly: weekly, change: change, fromLb: a.lb, toLb: b.lb)
    }

    // MARK: Doses

    /// A week after the last logged dose, unless that's on or after the retatrutide switch
    /// (web plannedDoses().next).
    public static func plannedNextDose(_ d: Dashboard) -> Date? {
        let list = d.doses.filter { $0.skipped != true && $0.doseMg != nil && $0.takenDate != nil }
        guard let last = list.last?.takenDate else { return nil }
        let next = last.addingTimeInterval(7 * 86400)
        return next >= LogTime.retaStart ? nil : next
    }

    // MARK: Days

    /// The first day anything was logged: the earliest of the first weigh-in, meal, Apple Health
    /// day and check-in.
    public static func earliestDay(_ d: Dashboard, now: Date = Date()) -> String {
        var keys: [String] = []
        if let t = d.weights.first?.measuredDate { keys.append(LogTime.dayKey(t)) }
        if let t = d.meals.first?.eatenDate { keys.append(LogTime.dayKey(t)) }
        if let h = d.dailyHealth.first, !h.day.isEmpty { keys.append(h.day) }
        if let c = d.checkins.first, !c.day.isEmpty { keys.append(c.day) }
        return keys.sorted().first ?? LogTime.today(now)
    }

    /// Days with a weigh-in, a meal or a check-in.
    public static func loggedDays(_ d: Dashboard) -> Set<String> {
        var set = Set<String>()
        for w in d.weights { if let t = w.measuredDate { set.insert(LogTime.dayKey(t)) } }
        for m in d.meals { if let t = m.eatenDate { set.insert(LogTime.dayKey(t)) } }
        for c in d.checkins where !c.day.isEmpty { set.insert(c.day) }
        return set
    }

    // MARK: Sleep

    /// A log.health_metrics value on a day.
    public static func metricValue(_ d: Dashboard, _ id: String, on key: String) -> Double? {
        d.healthMetrics[id]?.first { $0.day == key && $0.value.isFinite }?.value
    }

    /// Hours asleep that night: Apple Health's sleep hours, else time in bed, else the stages added up.
    public static func sleepHours(_ d: Dashboard, on key: String) -> Double? {
        if let h = d.dailyHealth.first(where: { $0.day == key }), let s = h.sleepHours { return s }
        if let inBed = metricValue(d, "sleep_in_bed_h", on: key) { return inBed }
        let parts = ["sleep_core_min", "sleep_deep_min", "sleep_rem_min"].map { metricValue(d, $0, on: key) }
        if parts.contains(where: { $0 != nil }) { return parts.reduce(0.0) { $0 + ($1 ?? 0) } / 60 }
        return nil
    }

    public static func sleepStages(_ d: Dashboard, on key: String) -> SleepStages? {
        let s = SleepStages(core: metricValue(d, "sleep_core_min", on: key), deep: metricValue(d, "sleep_deep_min", on: key),
                            rem: metricValue(d, "sleep_rem_min", on: key), awake: metricValue(d, "sleep_awake_min", on: key))
        if s.core == nil && s.deep == nil && s.rem == nil && s.awake == nil { return nil }
        return s
    }

    /// The night to show: the day being viewed, or for today the latest of today and yesterday
    /// that has sleep.
    public static func nightKey(_ d: Dashboard, view: String, now: Date = Date()) -> String {
        let today = LogTime.today(now)
        if view != today { return view }
        if sleepHours(d, on: today) != nil || sleepStages(d, on: today) != nil { return today }
        let y = LogTime.shift(today, -1)
        if sleepHours(d, on: y) != nil || sleepStages(d, on: y) != nil { return y }
        return today
    }

    // MARK: Off your normal

    public static let normalSignals: [SignalSpec] = [
        SignalSpec(id: "resting_hr", label: "Resting heart rate", daily: true, up: true, unit: "bpm", digits: 0, fixedFloor: 4),
        SignalSpec(id: "hrv_ms", label: "HRV", daily: true, up: false, unit: "ms", digits: 0, fixedFloor: 0),
        SignalSpec(id: "respiratory_rate", label: "Breathing rate", daily: false, up: true, unit: "/min", digits: 1, fixedFloor: 1.5),
        SignalSpec(id: "wrist_temp_f", label: "Wrist temperature", daily: false, up: true, unit: "°F", digits: 1, fixedFloor: 0.9),
    ]

    /// Each signal on `key` against the 30 days before it (at least 7 of them): the median, and a
    /// spread from the median absolute deviation. Off means past max(2 × spread, the floor).
    public static func offNormal(_ d: Dashboard, on key: String) -> [SignalCheck] {
        var out: [SignalCheck] = []
        let start = LogTime.shift(key, -30)
        for s in normalSignals {
            var m: [String: Double] = [:]
            if s.daily {
                let field: KeyPath<DailyHealth, Double?> = s.id == "resting_hr" ? \DailyHealth.restingHr : \DailyHealth.hrvMs
                for r in d.dailyHealth { if let v = r[keyPath: field] { m[r.day] = v } }
            } else {
                for p in metric(d, s.id) { m[p.key] = p.value }
            }
            guard let v = m[key] else { continue }
            var base: [Double] = []
            var k = start
            while k < key {
                if let x = m[k] { base.append(x) }
                k = LogTime.shift(k, 1)
            }
            guard base.count >= 7, let med = median(base), let mad = median(base.map { abs($0 - med) }) else { continue }
            let margin = max(2 * 1.4826 * mad, s.floor(median: med))
            let diff = v - med
            let off = s.up ? diff >= margin : -diff >= margin
            out.append(SignalCheck(spec: s, value: v, median: med, diff: diff, off: off))
        }
        return out
    }

    // MARK: Protein

    /// Protein left today and the days in a row at the target (today counts once it's hit).
    public static func proteinStreak(_ d: Dashboard, target: Double, now: Date = Date()) -> ProteinStreak {
        let today = LogTime.today(now)
        let todayPro = totals(on: today, d)?.proteinG
        let hit = todayPro.map { $0 >= target } ?? false
        var streak = 0
        var k = hit ? today : LogTime.shift(today, -1)
        for _ in 0..<400 {
            guard let p = totals(on: k, d)?.proteinG, p >= target else { break }
            streak += 1
            k = LogTime.shift(k, -1)
        }
        return ProteinStreak(target: target, streak: streak, remaining: max(0, target - (todayPro ?? 0)), hitToday: hit, todayProtein: todayPro)
    }
}
