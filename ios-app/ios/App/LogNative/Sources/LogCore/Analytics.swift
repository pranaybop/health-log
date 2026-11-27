import Foundation


public enum Sites {
    /// Rotation order.
    public static let all = ["Abd LR", "Abd LL", "Abd UR", "Abd UL", "Love L", "Love R"]
    public static let labels: [String: String] = [
        "Abd LR": "Lower right belly", "Abd LL": "Lower left belly",
        "Abd UR": "Upper right belly", "Abd UL": "Upper left belly",
        "Love L": "Left love handle", "Love R": "Right love handle",
    ]
    public static func label(_ site: String?) -> String { site.map { labels[$0] ?? $0 } ?? "—" }
}

/// A dated value on a calendar day, for charts and averages.
public struct DayValue: Hashable, Sendable {
    public var key: String
    public var value: Double
    public var date: Date { LogTime.noon(key) }
    public init(key: String, value: Double) { self.key = key; self.value = value }
}

/// A weigh-in with its smoothed trend.
public struct WeightPoint: Hashable, Sendable {
    public var at: Date
    public var lb: Double
    public var trend: Double
    public var day: String { LogTime.dayKey(at) }
}

public enum Analytics {

    // MARK: Medication

    /// Half-life in days: the protocol row's half_life_hours, else 6 for retatrutide and 5 otherwise.
    public static func halfLifeDays(_ compound: String?, protocols: [ProtocolRow]) -> Double {
        let c = (compound ?? "").lowercased()
        if let p = protocols.first(where: { ($0.compound ?? "").lowercased() == c }), let h = p.halfLifeHours, h > 0 {
            return h / 24
        }
        if c == "semaglutide" { return 7 }
        return c == "retatrutide" ? 6 : 5
    }

    /// Modeled mg in the body at `at`: each dose decays from the moment it was taken.
    public static func remaining(at: Date, doses: [Dose], protocols: [ProtocolRow]) -> Double {
        var total = 0.0
        for d in doses where d.counts {
            guard let t = d.takenDate, let mg = d.doseMg, at >= t else { continue }
            let days = at.timeIntervalSince(t) / 86400
            total += mg * pow(0.5, days / halfLifeDays(d.compound, protocols: protocols))
        }
        return total
    }

    /// How many days before its planned day a dose still counts for that week (a Saturday shot for
    /// a Sunday plan). Each plan week runs from this many days before its day to the same point
    /// before the next one, so every logged dose covers at most one week.
    public static let planEarlyDays = 3

    /// Planned doses no logged dose has covered yet, earliest first. A dose (taken or skipped)
    /// covers the plan row for the week it falls in: from planEarlyDays before that planned day
    /// to the same point before the next one. A missed week stays here until something is logged in it.
    public static func openPlan(_ d: Dashboard) -> [DosePlanRow] {
        let rows = d.dosePlan
            .filter { !$0.plannedOn.isEmpty && $0.doseMg != nil }
            .sorted { $0.plannedOn < $1.plannedOn }
        let days = d.doses.compactMap { dose -> String? in
            guard let t = dose.takenDate else { return nil }
            return LogTime.dayKey(t)
        }
        var open: [DosePlanRow] = []
        for (i, row) in rows.enumerated() {
            let start = LogTime.shift(row.plannedOn, -planEarlyDays)
            let end = i + 1 < rows.count ? LogTime.shift(rows[i + 1].plannedOn, -planEarlyDays) : "9999-12-31"
            if !days.contains(where: { $0 >= start && $0 < end }) { open.append(row) }
        }
        return open
    }

    /// The earliest planned dose still open, including one whose day has already passed.
    public static func nextPlanned(_ d: Dashboard) -> DosePlanRow? { openPlan(d).first }

    /// True when that planned day is already over and the dose is still open.
    public static func planIsOverdue(_ row: DosePlanRow, now: Date = Date()) -> Bool {
        row.plannedOn < LogTime.today(now)
    }

    /// The active protocol's next site, else the one after the last used site.
    public static func nextSite(_ d: Dashboard) -> String? {
        let used = d.doses.filter { $0.skipped != true && $0.site != nil && $0.takenDate != nil }
            .sorted { $0.takenDate! < $1.takenDate! }
        if let next = d.protocols.first(where: { $0.status == "active" })?.nextSite, !next.isEmpty { return next }
        guard let last = used.last?.site, let i = Sites.all.firstIndex(of: last) else { return nil }
        return Sites.all[(i + 1) % Sites.all.count]
    }

    public static func retaSwitchAt(_ d: Dashboard) -> Date {
        if let started = d.protocols.first(where: { ($0.compound ?? "").lowercased() == "retatrutide" })?.startedOn,
           !started.isEmpty {
            return LogTime.noon(started)
        }
        return LogTime.retaStart
    }

    // MARK: Weight

    /// Weigh-ins sorted by time with an exponentially smoothed trend (tau in days): each reading
    /// moves the trend by 1 - e^(-dt/tau), so a long gap counts almost fully and same-day repeats barely.
    public static func smoothWeights(_ d: Dashboard, tau: Double = 7) -> [WeightPoint] {
        let parsed = d.weights.compactMap { w -> (Date, Double)? in
            guard let at = w.measuredDate, let lb = w.weightLb else { return nil }
            return (at, lb)
        }.sorted { $0.0 < $1.0 }
        var out: [WeightPoint] = []
        var trend: Double?
        var prev: Date?
        for (at, lb) in parsed {
            if let t = trend, let p = prev {
                let dt = max(0, at.timeIntervalSince(p) / 86400)
                trend = t + (1 - exp(-dt / tau)) * (lb - t)
            } else {
                trend = lb
            }
            prev = at
            out.append(WeightPoint(at: at, lb: lb, trend: trend!))
        }
        return out
    }

    /// The trend as of `at` (the last weigh-in at or before it).
    public static func trend(at: Date, in points: [WeightPoint]) -> Double? {
        points.last(where: { $0.at <= at })?.trend
    }

    /// Trend change per week over the last `days` days (negative = losing).
    public static func trendRate(_ points: [WeightPoint], days: Double) -> Double? {
        guard points.count >= 2, let last = points.last,
              let from = trend(at: last.at.addingTimeInterval(-days * 86400), in: points) else { return nil }
        return (last.trend - from) / days * 7
    }

    // MARK: Series helpers

    /// A log.health_metrics series, sorted, finite values only.
    public static func metric(_ d: Dashboard, _ id: String) -> [DayValue] {
        (d.healthMetrics[id] ?? []).filter { $0.value.isFinite }.map { DayValue(key: $0.day, value: $0.value) }.sorted { $0.key < $1.key }
    }

    public static func median(_ values: [Double]) -> Double? {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        let m = v.count / 2
        return v.count % 2 == 1 ? v[m] : (v[m - 1] + v[m]) / 2
    }

    public static func mean(_ values: [Double]) -> Double? {
        let v = values.filter(\.isFinite)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    // MARK: Food

    public static func meals(on key: String, _ d: Dashboard) -> [Meal] {
        d.meals.filter { $0.eatenDate.map(LogTime.dayKey) == key }
    }

    /// The day's totals: the daily_totals row, else summed from that day's meals.
    public static func totals(on key: String, _ d: Dashboard) -> DailyTotal? {
        if let row = d.dailyTotals.first(where: { $0.date == key }) { return row }
        let m = meals(on: key, d)
        guard !m.isEmpty else { return nil }
        func sum(_ f: KeyPath<Meal, Double?>) -> Double { m.reduce(0) { $0 + ($1[keyPath: f] ?? 0) } }
        var t = DailyTotal(date: key)
        t.calories = sum(\.calories); t.proteinG = sum(\.proteinG); t.carbsG = sum(\.carbsG)
        t.fatG = sum(\.fatG); t.fiberG = sum(\.fiberG); t.mealCount = Double(m.count)
        return t
    }

    /// Calorie and protein targets: the active log.goals rows (set with goal_set).
    public static func targets(_ d: Dashboard) -> (calories: Double?, protein: Double?) {
        func goal(_ kinds: [String]) -> Double? {
            d.goals.first { kinds.contains(($0.kind ?? "").lowercased()) && ($0.status ?? "active").lowercased() == "active" && $0.target != nil }?.target
        }
        return (goal(["calories", "calorie", "kcal"]), goal(["protein", "protein_g"]))
    }
}

extension DailyTotal {
    public init(date: String) { self.date = date }
}
