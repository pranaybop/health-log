import Foundation

extension Analytics {
    public enum Trends {}
}

// MARK: - Shared types and text helpers

extension Analytics.Trends {
    public static let kcalPerLb = 3500.0

    public struct Point: Hashable, Sendable {
        public var at: Date
        public var value: Double
        public var key: String
        public init(at: Date, value: Double, key: String? = nil) {
            self.at = at
            self.value = value
            self.key = key ?? LogTime.dayKey(at)
        }
        public init(key: String, value: Double) {
            self.init(at: LogTime.noon(key), value: value, key: key)
        }
    }

    /// One column of a daily (or weekly) column chart. `value` nil means nothing logged.
    public struct Column: Hashable, Sendable, Identifiable {
        public var key: String
        public var value: Double?
        public var isToday: Bool
        public var id: String { key }
        public init(key: String, value: Double?, isToday: Bool = false) {
            self.key = key
            self.value = value
            self.isToday = isToday
        }
    }

    public struct Tile: Hashable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var detail: String?
        public var id: String { label }
        public init(_ label: String, _ value: String, _ detail: String?) {
            self.label = label
            self.value = value
            self.detail = detail
        }
    }

    public struct MeanN: Hashable, Sendable {
        public var mean: Double
        public var n: Int
    }

    private static let numberFormatters: [NumberFormatter] = (0...3).map { digits in
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.roundingMode = .halfUp
        return f
    }

    public static func num(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v, v.isFinite else { return "—" }
        return numberFormatters[max(0, min(3, digits))].string(from: NSNumber(value: v)) ?? "—"
    }

    /// signed: +1.2 · −0.4 (true minus) · 0.0
    public static func signed(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v, v.isFinite else { return "—" }
        let s = num(abs(v), digits)
        if v > 0 { return "+" + s }
        if v < 0 { return "−" + s }
        return s
    }

    /// "s" unless n is 1.
    public static func s(_ n: Int) -> String { n == 1 ? "" : "s" }

    public static func short(_ key: String?) -> String {
        guard let key, key.count >= 10 else { return "—" }
        return LogTime.shortDate(key: String(key.prefix(10)))
    }

    public static func capitalize(_ text: String) -> String {
        text.prefix(1).uppercased() + String(text.dropFirst())
    }

    public static func dateYear(_ date: Date, now: Date) -> String {
        let y = LogTime.calendar.component(.year, from: date)
        let base = LogTime.weekdayDate(date)
        return y == LogTime.calendar.component(.year, from: now) ? base : "\(base), \(y)"
    }

    /// dayTitle: Today, Yesterday, a weekday within the week, else the date.
    public static func dayTitle(_ key: String, now: Date) -> String {
        let off = LogTime.dayDiff(key, LogTime.today(now))
        if off == 0 { return "Today" }
        if off == -1 { return "Yesterday" }
        let d = LogTime.noon(key)
        if off > -7 { return LogTime.weekday(d) }
        return dateYear(d, now: now)
    }

    private static var dateTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = LogTime.calendar
        f.timeZone = LogTime.zone
        f.dateFormat = "EEE, MMM d, yyyy, h:mm a"
        return f
    }

    /// "Tue, Nov 24, 2026, 6:30 PM" plus the active zone's abbreviation.
    public static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date) + " " + (LogTime.zone.abbreviation(for: date) ?? LogTime.zone.identifier)
    }

    public static func dayRange(_ from: String, _ to: String) -> [String] {
        var out: [String] = []
        var k = from
        while k <= to && out.count < 5000 {
            out.append(k)
            k = LogTime.shift(k, 1)
        }
        return out
    }

    /// Trailing mean over `days` calendar days (inclusive), points sorted by key; keeps each time.
    public static func rolling(_ pts: [Point], days: Int = 7) -> [Point] {
        var out: [Point] = []
        var lo = 0
        var sum = 0.0
        for i in pts.indices {
            sum += pts[i].value
            while LogTime.dayDiff(pts[i].key, pts[lo].key) > days - 1 {
                sum -= pts[lo].value
                lo += 1
            }
            out.append(Point(at: pts[i].at, value: sum / Double(i - lo + 1), key: pts[i].key))
        }
        return out
    }

    /// A log.health_metrics series as day points.
    public static func metricPoints(_ d: Dashboard, _ id: String) -> [Point] {
        Analytics.metric(d, id).map { Point(key: $0.key, value: $0.value) }
    }

    public static func targets(_ d: Dashboard) -> (calories: Double?, protein: Double?) {
        Analytics.targets(d)
    }
}

// MARK: - Weight

extension Analytics.Trends {
    public struct LineFit: Hashable, Sendable {
        public var slope: Double
        public var intercept: Double
    }

    public static func linearFit(_ pts: [(x: Double, y: Double)]) -> LineFit? {
        guard let fit = Analytics.linearFit(pts) else { return nil }
        return LineFit(slope: fit.slope, intercept: fit.intercept)
    }

    public struct Pace: Hashable, Sendable {
        public var weekly: Double
        public var n: Int
    }

    /// Straight-line pace through the last `days` days of weigh-ins (one a day).
    public static func recentPace(_ parsed: [WeightPoint], days: Double = 28) -> Pace? {
        guard let pace = Analytics.recentPace(parsed, days: days) else { return nil }
        return Pace(weekly: pace.weekly, n: pace.count)
    }

    public struct LossRate: Hashable, Sendable {
        public var weekly: Double
        public var pct: Double
        public var fast: Bool
    }

    /// Loss as a share of body weight a week, from the 4-week fit.
    public static func lossRate(_ parsed: [WeightPoint]) -> LossRate? {
        guard let rate = Analytics.lossRate(parsed) else { return nil }
        return LossRate(weekly: rate.weekly, pct: rate.pct, fast: rate.fast)
    }

    public struct Projection: Hashable, Sendable {
        public var fit: LineFit
        public var weekly: Double
        public var last: WeightPoint
        public var base: Date
        public func value(at t: Date) -> Double { fit.intercept + fit.slope * (t.timeIntervalSince(base) / 86400) }
    }

    /// Straight-line fit of daily weigh-ins since the first tirzepatide dose.
    public static func weightProjection(_ parsed: [WeightPoint]) -> Projection? {
        let daily = Analytics.dailyWeight(parsed.filter { $0.at >= LogTime.tirzStart })
        guard daily.count >= 4, let first = daily.first, let last = daily.last else { return nil }
        guard let fit = linearFit(daily.map { (x: $0.at.timeIntervalSince(first.at) / 86400, y: $0.lb) }) else { return nil }
        return Projection(fit: fit, weekly: fit.slope * 7, last: last, base: first.at)
    }

    public static func firstGlp1At(_ d: Dashboard) -> Date {
        let times = d.doses.filter {
            $0.skipped != true && ($0.compound ?? "").range(of: "tirzepatide|retatrutide", options: [.regularExpression, .caseInsensitive]) != nil
        }.compactMap { $0.takenDate }.sorted()
        if let t = times.first { return t }
        if let p = Analytics.protocolRow(d, "tirzepatide"), let s = p.startedOn, s.count >= 10 { return LogTime.noon(String(s.prefix(10))) }
        return LogTime.tirzStart
    }

    public struct Stall: Hashable, Sendable {
        public var ready: Bool
        public var stalled: Bool
        public var summary: String
        public var changed: [String]
    }

    /// stallCheck: is the last 3 weeks of daily weigh-ins roughly flat, and what changed.
    public static func stallCheck(_ d: Dashboard, now: Date) -> Stall {
        let r = Analytics.stallCheck(Analytics.smoothWeights(d), now: now)
        if r.weighIns40 < 6 {
            let n = 6 - r.weighIns40
            return Stall(ready: false, stalled: false, summary: "Needs \(n) more weigh-in\(s(n)) in this window for a stall check.", changed: [])
        }
        guard r.ready, let from = r.fromDay, let to = r.toDay, let change = r.change, let weekly = r.weekly else {
            let n = 4 - r.weighIns21
            return Stall(ready: false, stalled: false, summary: "Needs \(n) more weigh-in\(s(n)) in the last 3 weeks.", changed: [])
        }
        let summary = r.stalled
            ? "Smoothed weight has been roughly flat for 3 weeks (\(num(r.fromLb, 1)) to \(num(r.toLb, 1)) lb)."
            : "No stall — weight moved \(num(change, 1)) lb over the last 3 weeks (\(num(weekly, 1)) lb/week)."
        return Stall(ready: true, stalled: r.stalled, summary: summary, changed: whatChanged(d, from: from, to: to))
    }

    static func whatChanged(_ d: Dashboard, from: String, to: String) -> [String] {
        var bits: [String] = []
        let doses = d.doses.filter { x in
            guard let t = x.takenDate else { return false }
            let k = LogTime.dayKey(t)
            return k >= from && k <= to
        }
        if !doses.isEmpty {
            let parts: [String] = doses.map { x in
                let amount = x.skipped == true ? "Skipped" : num(x.doseMg, 1) + " mg"
                let when = x.takenDate.map { LogTime.shortDate($0) } ?? ""
                return "\(amount) \(x.compound ?? "") on \(when)"
            }
            bits.append(parts.joined(separator: "; "))
        }
        let checkins = d.checkins.filter { $0.day >= from && $0.day <= to }
        let steps = checkins.compactMap { $0.steps }
        if let avg = Analytics.mean(steps) {
            bits.append("Average \(num(avg)) steps on \(steps.count) check-in days.")
        }
        let food = d.dailyTotals.filter { $0.date >= from && $0.date <= to && $0.calories != nil }
        if let avg = Analytics.mean(food.compactMap { $0.calories }) {
            bits.append("\(food.count) food day\(s(food.count)) logged, averaging \(num(avg)) calories.")
        }
        let feels = checkins.filter { !($0.doseFeel ?? "").isEmpty }
        if !feels.isEmpty { bits.append("Dose feel logged on \(feels.count) day\(s(feels.count)).") }
        return bits
    }

    public struct BodyComp: Hashable, Sendable {
        public var tiles: [Tile]
        public var lean: [Point]
        public var hasReadings: Bool
    }

    /// Body composition: BMI, body fat, lean mass and the share of loss that was lean.
    public static func bodyComp(_ d: Dashboard) -> BodyComp {
        var m: [(metric: String, at: Date, v: Double)] = []
        for r in d.measurements {
            if let at = r.measuredDate, let v = r.value { m.append((metric: r.metric ?? "", at: at, v: v)) }
        }
        let bf = m.filter { $0.metric == "body_fat_pct" }.sorted { $0.at < $1.at }
        let lean = m.filter { $0.metric == "lean_mass_lb" }.sorted { $0.at < $1.at }
        let parsed = Analytics.smoothWeights(d)
        var tiles: [Tile] = []
        if let cur = parsed.last, let h = d.profile?.heightIn, h > 0 {
            let bmi = 703 * cur.lb / (h * h)
            let feet = Int((h / 12).rounded(.down))
            let inches = Int(h.truncatingRemainder(dividingBy: 12).rounded())
            tiles.append(Tile("BMI", num(bmi, 1), "\(num(cur.lb, 1)) lb at \(feet)′\(inches)″"))
        }
        if let first = bf.first, let last = bf.last {
            let detail = bf.count > 1 ? "\(signed(last.v - first.v)) pts since \(LogTime.shortDate(first.at))" : LogTime.weekdayDate(first.at)
            tiles.append(Tile("Body fat", "\(num(last.v, 1))%", detail))
        }
        if let first = lean.first, let last = lean.last {
            let detail = lean.count > 1 ? "\(signed(last.v - first.v)) lb since \(LogTime.shortDate(first.at))" : LogTime.weekdayDate(first.at)
            tiles.append(Tile("Lean mass", "\(num(last.v, 1)) lb", detail))
        }
        if lean.count >= 2, let p0 = parsed.first, let l0 = lean.first, let l1 = lean.last {
            func nearest(_ t: Date) -> WeightPoint {
                parsed.reduce(p0) { best, w in abs(w.at.timeIntervalSince(t)) < abs(best.at.timeIntervalSince(t)) ? w : best }
            }
            let lost = nearest(l0.at).lb - nearest(l1.at).lb
            if lost > 2 {
                let share = max(0, min(1, (l0.v - l1.v) / lost))
                tiles.append(Tile("Loss that was lean", "\(Int((share * 100).rounded()))%", "lower is better"))
            }
        }
        return BodyComp(tiles: tiles, lean: lean.map { Point(at: $0.at, value: $0.v) }, hasReadings: !bf.isEmpty || !lean.isEmpty)
    }

    public struct Journey: Hashable, Sendable {
        public var current: WeightPoint
        public var startLb: Double
        public var goalLb: Double?
        public var changeStart: Double
        public var changeTirz: Double
    }

    public static func journey(_ d: Dashboard) -> Journey? {
        guard let j = Analytics.journey(d) else { return nil }
        return Journey(current: j.current, startLb: j.startLb, goalLb: j.goalLb,
                       changeStart: j.changeStart, changeTirz: j.current.lb - j.sinceTirz.lb)
    }

    /// The verdict label (verdictCard), used in the prescriber report.
    public static func verdictLabel(_ d: Dashboard, now: Date) -> String {
        guard let j = journey(d) else { return "Building" }
        let daysOn = now.timeIntervalSince(LogTime.tirzStart) / 86400
        if daysOn < 10 && j.changeStart > -2 { return "Building" }
        if stallCheck(d, now: now).stalled { return "Worth watching" }
        if j.changeStart <= -8 { return "Working" }
        if abs(j.changeStart) < 2 { return "Steady" }
        if j.changeStart > 2 { return "Worth watching" }
        return "Working"
    }
}

// MARK: - Overlays under the weight chart

extension Analytics.Trends {
    /// Food thoughts a day, zero-filled from the first one through today.
    public static func thoughtsByDay(_ d: Dashboard, now: Date) -> [String: Double] {
        var out: [String: Double] = [:]
        var first: String?
        for t in d.foodThoughts {
            guard let at = t.thoughtDate else { continue }
            let k = LogTime.dayKey(at)
            out[k, default: 0] += 1
            if first == nil || k < first! { first = k }
        }
        if let first {
            for k in dayRange(first, LogTime.today(now)) where out[k] == nil { out[k] = 0 }
        }
        return out
    }

    public static func noiseByDay(_ d: Dashboard) -> [String: Double] {
        var out: [String: Double] = [:]
        for c in d.checkins { if let v = c.foodNoise { out[c.day] = v } }
        return out
    }

    /// overlayDaily: the daily values of a compare-with series.
    public static func overlayDaily(_ d: Dashboard, _ id: String, now: Date) -> [String: Double] {
        if id == "thoughts" { return thoughtsByDay(d, now: now) }
        if id == "noise" { return noiseByDay(d) }
        var out: [String: Double] = [:]
        if id == "calories" {
            for r in d.dailyTotals { if let v = r.calories, v > 0 { out[r.date] = v } }
            return out
        }
        let field: KeyPath<DailyHealth, Double?>
        switch id {
        case "steps": field = \.steps
        case "sleep": field = \.sleepHours
        case "rhr": field = \.restingHr
        case "hrv": field = \.hrvMs
        default: return out
        }
        for r in d.dailyHealth { if let v = r[keyPath: field], v > 0 { out[r.day] = v } }
        return out
    }

    public struct OverlayPoint: Hashable, Sendable {
        public var at: Date
        public var value: Double
        public var key: String
        public var n: Int
        public var day: Double?
    }

    /// overlayPoints: a 7-day average per day, or weekly averages (Monday weeks, drawn mid-week).
    public static func overlayPoints(_ daily: [String: Double], weekly: Bool) -> [OverlayPoint] {
        let keys = daily.keys.sorted()
        if !weekly {
            return keys.map { k in
                var sum = 0.0
                var n = 0
                for i in 0..<7 { if let v = daily[LogTime.shift(k, -i)] { sum += v; n += 1 } }
                return OverlayPoint(at: LogTime.noon(k), value: sum / Double(max(1, n)), key: k, n: n, day: daily[k])
            }
        }
        var order: [String] = []
        var weeks: [String: (sum: Double, n: Int)] = [:]
        for k in keys {
            let m = LogTime.monday(k)
            if weeks[m] == nil { order.append(m); weeks[m] = (0, 0) }
            weeks[m]!.sum += daily[k] ?? 0
            weeks[m]!.n += 1
        }
        return order.map { m in
            let w = weeks[m]!
            return OverlayPoint(at: LogTime.noon(m).addingTimeInterval(3 * 86400), value: w.sum / Double(w.n), key: m, n: w.n, day: nil)
        }
    }
}

// MARK: - Food

extension Analytics.Trends {
    public struct FoodSeries: Hashable, Sendable {
        public var title: String
        public var unit: String
        public var days: [Column]
        public var average: Double
        public var target: Double?
        public var readoutSub: String
    }

    public struct FoodTrends: Hashable, Sendable {
        /// Logged days in the last 30, oldest first.
        public var logged: [String]
        public var rows: [String: DailyTotal]
        public var calories: FoodSeries?
        public var protein: FoodSeries?
    }

    public static func foodTrends(_ d: Dashboard, now: Date, calorieTarget: Double?, proteinTarget: Double?) -> FoodTrends {
        var byDay: [String: DailyTotal] = [:]
        for r in d.dailyTotals { byDay[r.date] = r }
        let keys = LogTime.lastDays(30, now: now)
        let today = LogTime.today(now)
        let logged = keys.filter { byDay[$0] != nil }
        guard logged.count >= 3 else { return FoodTrends(logged: logged, rows: byDay, calories: nil, protein: nil) }
        func series(_ field: KeyPath<DailyTotal, Double?>, protein: Bool, target: Double?, unit: String, title: String) -> FoodSeries {
            let days = keys.map { k in Column(key: k, value: byDay[k]?[keyPath: field], isToday: k == today) }
            let vals = days.compactMap { $0.value }
            let avg = Analytics.mean(vals) ?? 0
            var sub = "\(vals.count) logged days"
            if let target {
                let hit = vals.filter { protein ? $0 >= target : $0 <= target }.count
                sub = "\(hit) of \(vals.count) logged days \(protein ? "at or above" : "at or under") target"
            }
            return FoodSeries(title: title, unit: unit, days: days, average: avg, target: target, readoutSub: sub)
        }
        return FoodTrends(logged: logged, rows: byDay,
                          calories: series(\.calories, protein: false, target: calorieTarget, unit: "kcal", title: "Calories"),
                          protein: series(\.proteinG, protein: true, target: proteinTarget, unit: "g", title: "Protein"))
    }

    public struct Maintenance: Hashable, Sendable {
        public var start: String
        public var end: String
        public var burn: [Point]
        public var watch: Double?
        public var logged: [Point]
        public var intake: Double?
        public var rate: Double?
        public var fromLogs: Double?
        public var weighIns: Int
        public var best: Double? { fromLogs ?? watch }
    }

    /// Apple Watch total burned on full days in [from, to], skipping days under 70% of the median.
    public static func completeBurnDays(_ d: Dashboard, from: String, to: String, now: Date) -> [Point] {
        let today = LogTime.today(now)
        let pts = metricPoints(d, "total_kcal").filter { $0.key >= from && $0.key <= to && $0.key < today }
        guard let med = Analytics.median(pts.map(\.value)) else { return [] }
        return pts.filter { $0.value >= 0.7 * med }
    }

    /// maintenanceEstimate: the last 4 full weeks of burn, intake and weight trend.
    public static func maintenance(_ d: Dashboard, now: Date) -> Maintenance {
        let end = LogTime.shift(LogTime.today(now), -1)
        let start = LogTime.shift(end, -27)
        let days = 28.0
        let burn = completeBurnDays(d, from: start, to: end, now: now)
        let watch = burn.count >= 7 ? Analytics.median(burn.map(\.value)) : nil
        let logged = d.dailyTotals
            .filter { $0.date >= start && $0.date <= end && ($0.calories ?? 0) >= 800 }
            .map { Point(key: $0.date, value: $0.calories ?? 0) }
            .sorted { $0.key < $1.key }
        let intake = Analytics.mean(logged.map(\.value))
        let sm = Analytics.smoothWeights(d)
        let startTrend = Analytics.trend(at: LogTime.noon(start), in: sm)
        let endTrend = Analytics.trend(at: LogTime.noon(end).addingTimeInterval(12 * 3600), in: sm)
        let weighIns = sm.filter { $0.day >= start && $0.day <= end }.count
        var change: Double?
        if let a = startTrend, let b = endTrend, weighIns >= 6 { change = b - a }
        let rate = change.map { $0 / days * 7 }
        var fromLogs: Double?
        if logged.count >= 14, let c = change, let i = intake { fromLogs = i - c * kcalPerLb / days }
        return Maintenance(start: start, end: end, burn: burn, watch: watch, logged: logged, intake: intake,
                           rate: rate, fromLogs: fromLogs, weighIns: weighIns)
    }

    public struct ProteinCard: Hashable, Sendable {
        public var tiles: [Tile]
    }

    public static func proteinCard(_ d: Dashboard, now: Date, target: Double?) -> ProteinCard? {
        let today = LogTime.today(now)
        let rows = d.dailyTotals.filter { $0.date >= LogTime.shift(today, -29) && $0.proteinG != nil }
        guard !rows.isEmpty else { return nil }
        let vals = rows.compactMap { $0.proteinG }
        let avg = Analytics.mean(vals) ?? 0
        let last7 = rows.filter { $0.date >= LogTime.shift(today, -6) }.compactMap { $0.proteinG }
        let avg7 = Analytics.mean(last7)
        let hits = target.map { t in vals.filter { $0 >= t }.count }
        let tiles = [
            Tile("Days at target", hits.map { "\($0) of \(rows.count)" } ?? "—", target.map { "\(num($0)) g or more, last 30 days" } ?? "Set a target on Today"),
            Tile("Average", "\(num(avg)) g", "\(rows.count) logged day\(s(rows.count))"),
            Tile("Last 7 days", avg7.map { "\(num($0)) g" } ?? "—", "average a logged day"),
            Tile("Short by", target.map { "\(num(max(0, $0 - avg))) g" } ?? "—", "average gap to target"),
        ]
        return ProteinCard(tiles: tiles)
    }

    public struct ThoughtsCard: Hashable, Sendable {
        public var days: [Column]
        public var perDay: Double
        public var total: Int
        public var firstKey: String
        public var peakLabel: String
        public var strong: Int
        public var count: Int
    }

    public static func thoughtsCard(_ d: Dashboard, now: Date) -> ThoughtsCard? {
        var all: [(at: Date, strength: Double?)] = []
        for t in d.foodThoughts { if let at = t.thoughtDate { all.append((at: at, strength: t.strength)) } }
        guard let first = all.first else { return nil }
        let firstKey = LogTime.dayKey(first.at)
        let today = LogTime.today(now)
        let keys = LogTime.lastDays(30, now: now).filter { $0 >= firstKey }
        var counts: [String: Double] = [:]
        var hours = [Int](repeating: 0, count: 24)
        for t in all {
            counts[LogTime.dayKey(t.at), default: 0] += 1
            hours[LogTime.hour(t.at)] += 1
        }
        let days = keys.map { Column(key: $0, value: counts[$0] ?? 0, isToday: $0 == today) }
        let total = Int(days.reduce(0.0) { $0 + ($1.value ?? 0) })
        let peak = hours.firstIndex(of: hours.max() ?? 0) ?? 0
        let peakLabel = peak == 0 ? "12 AM" : peak < 12 ? "\(peak) AM" : peak == 12 ? "12 PM" : "\(peak - 12) PM"
        let strong = all.filter { ($0.strength ?? 0) >= 2 }.count
        return ThoughtsCard(days: days, perDay: Double(total) / Double(max(1, keys.count)), total: total, firstKey: firstKey,
                            peakLabel: peakLabel, strong: strong, count: all.count)
    }
}

// MARK: - Medication

extension Analytics.Trends {
    /// The modeled level as a share of the steady peak, fast enough to ask for every hour.
    public struct LevelModel: Sendable {
        let doses: [(at: Date, mg: Double, comp: String, halfLife: Double)]

        public init(_ d: Dashboard) {
            doses = d.doses.filter(\.counts).compactMap { x -> (at: Date, mg: Double, comp: String, halfLife: Double)? in
                guard let at = x.takenDate, let mg = x.doseMg else { return nil }
                let comp = (x.compound ?? "").lowercased()
                return (at, mg, comp, Analytics.halfLifeDays(comp, protocols: d.protocols))
            }.sorted { $0.at < $1.at }
        }

        public var isEmpty: Bool { doses.isEmpty }

        public func share(at t: Date) -> Double? {
            guard let lastIndex = doses.lastIndex(where: { $0.at <= t }) else { return nil }
            let last = doses[lastIndex]
            let peak = last.mg / (1 - pow(0.5, 7 / last.halfLife))
            guard peak > 0 else { return nil }
            var total = 0.0
            for i in 0...lastIndex where doses[i].comp == last.comp {
                let days = t.timeIntervalSince(doses[i].at) / 86400
                total += doses[i].mg * pow(0.5, days / doses[i].halfLife)
            }
            return total / peak
        }
    }

    public struct LevelBin: Hashable, Sendable {
        public var label: String
        public var sub: String
        public var lo: Double
        public var hi: Double
    }

    public static let levelBins = [
        LevelBin(label: "Low", sub: "under 55%", lo: 0, hi: 0.55),
        LevelBin(label: "Middle", sub: "55–75%", lo: 0.55, hi: 0.75),
        LevelBin(label: "High", sub: "75% and up", lo: 0.75, hi: .infinity),
    ]

    public static func binOf(_ share: Double) -> Int {
        levelBins.firstIndex { share >= $0.lo && share < $0.hi } ?? 0
    }

    public struct BinStat: Hashable, Sendable {
        public var n: Int
        public var avg: Double?
        public var perDay: Double?
        public var days: Double
    }

    public struct Appetite: Hashable, Sendable {
        public var noise: [BinStat]
        public var thoughts: [BinStat]
        public var trackedDays: Double
        public var nowShare: Double?
        public var lead: String
        public var noiseCount: Int
    }

    /// appetiteByLevel: food noise and food thoughts by modeled level band. nil hides the card.
    public static func appetite(_ d: Dashboard, now: Date) -> Appetite? {
        let level = LevelModel(d)
        guard !level.isEmpty else { return nil }
        var noise: [[Double]] = levelBins.map { _ in [] }
        for c in d.checkins {
            guard let v = c.foodNoise, !c.day.isEmpty else { continue }
            // Rated in the evening check-in: 8 PM that day (the payload has no check-in time).
            let at = LogTime.noon(c.day).addingTimeInterval(8 * 3600)
            guard let share = level.share(at: at) else { continue }
            noise[binOf(share)].append(v)
        }
        var thoughts = [Int](repeating: 0, count: levelBins.count)
        var hours = [Double](repeating: 0, count: levelBins.count)
        let times = d.foodThoughts.compactMap { $0.thoughtDate }.sorted()
        var trackedDays = 0.0
        if let firstTime = times.first {
            let from = LogTime.noon(LogTime.dayKey(firstTime)).addingTimeInterval(-12 * 3600)
            trackedDays = now.timeIntervalSince(from) / 86400
            var t = from
            while t < now {
                if let share = level.share(at: t) { hours[binOf(share)] += 1 }
                t = t.addingTimeInterval(3600)
            }
            for at in times { if let share = level.share(at: at) { thoughts[binOf(share)] += 1 } }
        }
        let noiseStats = noise.map { BinStat(n: $0.count, avg: Analytics.mean($0), perDay: nil, days: 0) }
        let thoughtStats = (0..<levelBins.count).map { i in
            BinStat(n: thoughts[i], avg: nil, perDay: hours[i] >= 12 ? Double(thoughts[i]) / (hours[i] / 24) : nil, days: hours[i] / 24)
        }
        let noiseN = noiseStats.reduce(0) { $0 + $1.n }
        let lo = noiseStats[0]
        let hi = noiseStats[2]
        let lead: String
        if lo.n >= 3, hi.n >= 3, let a = lo.avg, let b = hi.avg {
            let gap = a - b
            lead = abs(gap) < 0.5
                ? "Food noise is about the same at low and high levels so far."
                : "Food noise runs \(num(abs(gap), 1)) points \(gap > 0 ? "lower" : "higher") when the level is high than when it's low."
        } else if noiseN < 5 {
            lead = "Needs at least 5 check-ins with food noise to compare (\(noiseN) so far)."
        } else {
            lead = "Needs 3 check-ins at both low and high levels to compare."
        }
        return Appetite(noise: noiseStats, thoughts: thoughtStats, trackedDays: trackedDays, nowShare: level.share(at: now),
                        lead: lead, noiseCount: noiseN)
    }

    public struct WeekRow: Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var averages: [Double?]
        public var counts: [Int]
    }

    /// Sorted shot days (not skipped), for "days since the shot".
    static func shotDays(_ d: Dashboard) -> [String] {
        Array(Set(d.doses.filter { $0.skipped != true }.compactMap { $0.takenDate.map(LogTime.dayKey) })).sorted()
    }

    /// shotDayIndex: 0 on a shot day, up to 6 after; nil otherwise.
    static func shotDayIndex(_ shots: [String], _ key: String) -> Int? {
        guard let best = shots.last(where: { $0 <= key }) else { return nil }
        let n = LogTime.dayDiff(key, best)
        return (0...6).contains(n) ? n : nil
    }

    /// nil hides the card (no real doses); rows with no data at all mean the empty note.
    public static func shotWeek(_ d: Dashboard, now: Date) -> [WeekRow]? {
        guard d.doses.contains(where: { $0.skipped != true }) else { return nil }
        let shots = shotDays(d)
        var sums: [String: [Double]] = [:]
        var ns: [String: [Int]] = [:]
        let ids = ["noise", "thoughts", "effects", "energy"]
        for id in ids { sums[id] = [Double](repeating: 0, count: 7); ns[id] = [Int](repeating: 0, count: 7) }
        func add(_ row: String, _ key: String, _ v: Double?) {
            guard let v, v.isFinite, let i = shotDayIndex(shots, key) else { return }
            sums[row]![i] += v
            ns[row]![i] += 1
        }
        for c in d.checkins {
            add("noise", c.day, c.foodNoise)
            add("energy", c.day, c.energy)
        }
        var thoughtDays: [String: Double] = [:]
        for t in d.foodThoughts { if let at = t.thoughtDate { thoughtDays[LogTime.dayKey(at), default: 0] += 1 } }
        if let first = thoughtDays.keys.min() {
            for k in dayRange(first, LogTime.today(now)) { add("thoughts", k, thoughtDays[k] ?? 0) }
        }
        var effects: [String: Double] = [:]
        for e in d.sideEffects {
            guard let v = e.severity, let k = e.recordedOn else { continue }
            effects[k] = max(effects[k] ?? 0, v)
        }
        for (k, v) in effects { add("effects", k, v) }
        let labels = ["noise": "Food noise", "thoughts": "Food thoughts", "effects": "Side effects", "energy": "Energy"]
        return ids.map { id in
            let sum = sums[id]!
            let n = ns[id]!
            return WeekRow(id: id, label: labels[id]!, averages: (0..<7).map { n[$0] > 0 ? sum[$0] / Double(n[$0]) : nil }, counts: n)
        }
    }

    public struct WindowStats: Hashable, Sendable {
        public var delta: Double?
        public var noise: Double?
        public var energy: Double?
        public var effectAvg: Double?
        public var rhr: Double?
        public var hrv: Double?
        public var burn: Double?
        public var sleep: Double?
    }

    static func windowStats(_ d: Dashboard, from: String, to: String, now: Date) -> WindowStats {
        func inWin(_ k: String?) -> Bool { guard let k else { return false }; return k >= from && k <= to }
        let weights = Analytics.smoothWeights(d).filter { inWin($0.day) }
        var delta: Double?
        if let a = weights.first?.lb, let b = weights.last?.lb { delta = b - a }
        let checkins = d.checkins.filter { inWin($0.day) }
        let effects = d.sideEffects.filter { inWin($0.recordedOn) }
        let health = d.dailyHealth.filter { inWin($0.day) }
        let burnDays = completeBurnDays(d, from: from, to: to, now: now)
        let sleep = dayRange(from, to).compactMap { Analytics.sleepHours(d, on: $0) }
        return WindowStats(
            delta: delta,
            noise: Analytics.mean(checkins.compactMap { $0.foodNoise }),
            energy: Analytics.mean(checkins.compactMap { $0.energy }),
            effectAvg: Analytics.mean(effects.compactMap { $0.severity }),
            rhr: Analytics.mean(health.compactMap { $0.restingHr }),
            hrv: Analytics.mean(health.compactMap { $0.hrvMs }),
            burn: burnDays.count >= 3 ? Analytics.median(burnDays.map(\.value)) : nil,
            sleep: Analytics.mean(sleep))
    }

    public struct RetaVsTirz: Hashable, Sendable {
        public var lead: String
        public var tirz: WindowStats
        public var reta: WindowStats?
    }

    public static func retaVsTirz(_ d: Dashboard, now: Date) -> RetaVsTirz {
        let today = LogTime.today(now)
        let reta0 = Analytics.firstRetaDose(d)?.takenDate.map(LogTime.dayKey)
        let tirz1 = LogTime.shift(reta0 ?? today, -1)
        let tirz0 = LogTime.shift(tirz1, -27)
        let a = windowStats(d, from: tirz0, to: tirz1, now: now)
        var b: WindowStats?
        let lead: String
        if let reta0 {
            b = windowStats(d, from: reta0, to: LogTime.shift(reta0, 13), now: now)
            let retaDays = min(14, LogTime.dayDiff(today, reta0) + 1)
            lead = "Last 4 weeks on tirzepatide (\(short(tirz0))–\(short(tirz1))) vs the first \(max(1, retaDays)) day\(s(retaDays)) on retatrutide."
        } else {
            lead = "Your tirzepatide baseline for the last 4 full weeks (\(short(tirz0))–\(short(tirz1))). The retatrutide column starts with your first dose (planned \(LogTime.weekdayDate(Analytics.retaSwitchAt(d))))."
        }
        return RetaVsTirz(lead: lead, tirz: a, reta: b)
    }

    public struct Cycle: Hashable, Sendable {
        public var index: Int
        public var startAt: Date
        public var startMg: Double?
        public var startDay: String
        public var endDay: String
        public var open: Bool
    }

    /// cyclesFromDoses: each shot (not skipped) to the next one; the last is open.
    public static func cycles(_ d: Dashboard, now: Date) -> [Cycle] {
        let shots = d.doses.filter { $0.skipped != true && $0.takenDate != nil }.sorted { $0.takenDate! < $1.takenDate! }
        return shots.indices.map { i in
            let at = shots[i].takenDate!
            let next = i + 1 < shots.count ? shots[i + 1].takenDate : nil
            return Cycle(index: i + 1, startAt: at, startMg: shots[i].doseMg, startDay: LogTime.dayKey(at),
                         endDay: next.map(LogTime.dayKey) ?? LogTime.today(now), open: next == nil)
        }
    }

    public struct CycleRecap: Hashable, Sendable, Identifiable {
        public var cycle: Cycle
        public var delta: Double?
        public var ate: String?
        public var moved: String?
        public var feel: String?
        public var foodNoise: Double?
        public var steps: Double?
        public var vsPrevWeight: Double?
        public var id: Int { cycle.index }
    }

    static func mode(_ values: [String?]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for v in values {
            guard let v, !v.isEmpty else { continue }
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        var best: String?
        for v in order where best == nil || counts[v]! > counts[best!]! { best = v }
        return best
    }

    /// cycleRecaps: weight change and how each cycle went.
    public static func cycleRecaps(_ d: Dashboard, now: Date) -> [CycleRecap] {
        let daily = Analytics.dailyWeight(Analytics.smoothWeights(d))
        func weightOn(_ day: String) -> WeightPoint? { daily.last { $0.day <= day } }
        var out: [CycleRecap] = []
        for c in cycles(d, now: now) {
            let checkins = d.checkins.filter { $0.day >= c.startDay && ($0.day < c.endDay || (c.open && $0.day == c.endDay)) }
            var delta: Double?
            if let w0 = weightOn(c.startDay), let w1 = weightOn(c.endDay) { delta = w1.lb - w0.lb }
            var rec = CycleRecap(cycle: c, delta: delta,
                                 ate: mode(checkins.map(\.ateVsUsual)), moved: mode(checkins.map(\.movedVsUsual)), feel: mode(checkins.map(\.doseFeel)),
                                 foodNoise: Analytics.mean(checkins.compactMap { $0.foodNoise }), steps: Analytics.mean(checkins.compactMap { $0.steps }),
                                 vsPrevWeight: nil)
            if let prev = out.last, let a = rec.delta, let b = prev.delta { rec.vsPrevWeight = a - b }
            out.append(rec)
        }
        return out
    }

    public struct WearOff: Hashable, Sendable {
        public var ready: Bool
        public var summary: String
        public var details: [String]
    }

    /// wearOff: fading tags or rising food noise late in completed cycles (days 5-7).
    public static func wearOff(_ d: Dashboard, now: Date) -> WearOff {
        let all = cycles(d, now: now)
        if all.count < 2 {
            return WearOff(ready: false, summary: "Needs 2 completed cycles with late-cycle check-ins for wear-off detection.", details: [])
        }
        var flagged = 0
        var considered = 0
        var details: [String] = []
        for c in all where !c.open {
            let checkins = d.checkins.filter { $0.day >= c.startDay && $0.day < c.endDay }
            let early = checkins.filter { LogTime.dayDiff($0.day, c.startDay) <= 3 }
            let late = checkins.filter { LogTime.dayDiff($0.day, c.startDay) >= 5 }
            let lateFeel = late.filter { $0.doseFeel == "fading" || $0.doseFeel == "not_feeling_it" }.count
            let earlyN = Analytics.mean(early.compactMap { $0.foodNoise })
            let lateN = Analytics.mean(late.compactMap { $0.foodNoise })
            if lateFeel == 0 && lateN == nil { continue }
            considered += 1
            var noiseRise = false
            if let a = earlyN, let b = lateN { noiseRise = b - a >= 2 }
            let fading = lateFeel > 0
            if noiseRise || fading {
                flagged += 1
                let text = (fading ? "fading tags" : "") + (fading && noiseRise ? " and " : "") + (noiseRise ? "late-cycle food noise rose" : "")
                details.append("Cycle \(c.index): \(text).")
            }
        }
        if considered == 0 {
            return WearOff(ready: false, summary: "Needs late-cycle food-noise or feel tags (days 5–7) to detect wear-off.", details: [])
        }
        return WearOff(ready: true, summary: "Wear-off pattern in \(flagged) of \(considered) completed cycle\(s(considered)).", details: details)
    }

    public struct FeelReport: Hashable, Sendable {
        public var ready: Bool
        public var summary: String
        public var count: Int
        public var mood: MeanN?
        public var energy: MeanN?
        public var foodNoise: MeanN?
        public var sleepQuality: MeanN?
    }

    /// feelReport: average scores once 7 days have them.
    public static func feelReport(_ d: Dashboard) -> FeelReport {
        let rows = d.checkins.filter { $0.mood != nil || $0.energy != nil || $0.foodNoise != nil || $0.sleepQuality != nil }
        if rows.count < 7 {
            let n = 7 - rows.count
            return FeelReport(ready: false, summary: "Needs \(n) more day\(s(n)) with mood, energy, food noise or sleep scores.", count: rows.count)
        }
        func avg(_ f: KeyPath<Checkin, Double?>) -> MeanN? {
            let v = rows.compactMap { $0[keyPath: f] }
            return Analytics.mean(v).map { MeanN(mean: $0, n: v.count) }
        }
        return FeelReport(ready: true, summary: "", count: rows.count, mood: avg(\.mood), energy: avg(\.energy),
                          foodNoise: avg(\.foodNoise), sleepQuality: avg(\.sleepQuality))
    }

    /// planDoseText: "Tirzepatide 3.0 mg (30 units)"
    public static func planDoseText(_ r: DosePlanRow) -> String {
        "\(capitalize(r.compound ?? "")) \(num(r.doseMg, 1)) mg\(r.units.map { " (\(num($0)) units)" } ?? "")"
    }
}

// MARK: - Body

extension Analytics.Trends {
    public struct SignalDef: Hashable, Sendable {
        public var id: String
        public var label: String
        public var lower: String
        public var daily: Bool
        public var up: Bool
        public var unit: String
        public var digits: Int
        var unitText: String { unit == "/min" || unit == "°F" ? unit : " " + unit }
    }

    /// Sentence labels for the same signals as `Analytics.normalSignals`, in that order.
    public static let signalDefs: [SignalDef] = Analytics.normalSignals.map { s in
        SignalDef(id: s.id, label: s.label, lower: s.id == "hrv_ms" ? "HRV" : s.label.lowercased(),
                  daily: s.daily, up: s.up, unit: s.unit, digits: s.digits)
    }

    public struct SignalCheck: Hashable, Sendable {
        public var def: SignalDef
        public var value: Double
        public var median: Double
        public var diff: Double
        public var off: Bool
        /// fmtSignalDiff: "+8 bpm", "−42%", "+1.6/min"
        public var diffText: String {
            if def.id == "hrv_ms" { return "\(Analytics.Trends.signed(diff / median * 100, 0))%" }
            return Analytics.Trends.signed(diff, def.digits) + def.unitText
        }
        /// fmtSignal: "72 bpm", "17.6/min"
        public func text(_ v: Double) -> String { Analytics.Trends.num(v, def.digits) + def.unitText }
    }

    public struct OffNormal: Hashable, Sendable {
        public var key: String
        public var checked: [SignalCheck]
        public var off: [SignalCheck] { checked.filter(\.off) }
    }

    /// Each recovery signal's values by day.
    public static func signalMaps(_ d: Dashboard) -> [String: [String: Double]] {
        var maps: [String: [String: Double]] = [:]
        for s in Analytics.normalSignals { maps[s.id] = Analytics.signalSeries(s, d) }
        return maps
    }

    /// offNormal: each signal on `key` against the median and spread of the 30 days before it.
    public static func offNormal(_ maps: [String: [String: Double]], key: String) -> OffNormal {
        var checked: [SignalCheck] = []
        for (spec, def) in zip(Analytics.normalSignals, signalDefs) {
            guard let values = maps[spec.id], let hit = Analytics.signalOff(values, on: key, spec) else { continue }
            checked.append(SignalCheck(def: def, value: hit.value, median: hit.median, diff: hit.diff, off: hit.off))
        }
        return OffNormal(key: key, checked: checked)
    }

    public struct OffDay: Hashable, Sendable, Identifiable {
        public var key: String
        public var checked: Int
        public var off: [SignalCheck]
        public var flagged: Bool { off.count >= 2 }
        public var id: String { key }
    }

    public struct OffTrends: Hashable, Sendable {
        public var latest: OffNormal?
        public var days: [OffDay]
        public var tracked: Int
        public var flagged: [OffDay] { days.filter(\.flagged) }
    }

    public static func offNormalTrends(_ d: Dashboard, now: Date) -> OffTrends? {
        let maps = signalMaps(d)
        let today = LogTime.today(now)
        var latest: OffNormal?
        for i in 0..<3 {
            let r = offNormal(maps, key: LogTime.shift(today, -i))
            if r.checked.count >= 2 { latest = r; break }
        }
        let days: [OffDay] = (0..<60).reversed().map { i in
            let k = LogTime.shift(today, -i)
            let r = offNormal(maps, key: k)
            return OffDay(key: k, checked: r.checked.count, off: r.off)
        }
        let tracked = days.filter { $0.checked >= 2 }.count
        if latest == nil && tracked == 0 { return nil }
        return OffTrends(latest: latest, days: days, tracked: tracked)
    }

    public struct HeartPanel: Hashable, Sendable {
        public var title: String
        public var unit: String
        public var points: [Point]
        public var smooth: [Point]
        public var recent: Double?
        public var base: Double?
        public var higherIsBetter: Bool
        public var delta: Double? {
            guard let recent, let base else { return nil }
            return recent - base
        }
    }

    static func avgBetween(_ pts: [Point], _ from: String, _ to: String) -> Double? {
        Analytics.mean(pts.filter { $0.key >= from && $0.key <= to }.map(\.value))
    }

    public static func heart(_ d: Dashboard, now: Date) -> [HeartPanel] {
        let today = LogTime.today(now)
        let tirzKey = LogTime.dayKey(LogTime.tirzStart)
        func panel(_ field: KeyPath<DailyHealth, Double?>, _ title: String, _ unit: String, _ higher: Bool) -> HeartPanel? {
            let pts = d.dailyHealth.compactMap { r in r[keyPath: field].map { Point(key: r.day, value: $0) } }
            guard pts.count >= 3 else { return nil }
            return HeartPanel(title: title, unit: unit, points: pts, smooth: rolling(pts, days: 7),
                              recent: avgBetween(pts, LogTime.shift(today, -6), today),
                              base: avgBetween(pts, LogTime.shift(tirzKey, -30), LogTime.shift(tirzKey, -1)),
                              higherIsBetter: higher)
        }
        return [panel(\.restingHr, "Resting heart rate", "bpm", false), panel(\.hrvMs, "Heart rate variability", "ms", true)].compactMap { $0 }
    }

    public struct MeasureSeries: Hashable, Sendable, Identifiable {
        public var name: String
        public var unit: String
        public var points: [Point]
        public var id: String { name }
    }

    public static func measurements(_ d: Dashboard) -> [MeasureSeries] {
        let rows = d.measurements.filter { $0.metric != "body_fat_pct" && $0.metric != "lean_mass_lb" }
        var order: [String] = []
        var groups: [String: [Measurement]] = [:]
        for r in rows {
            let name = r.metric ?? ""
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(r)
        }
        return order.map { name in
            let sorted = groups[name]!.filter { $0.measuredDate != nil && $0.value != nil }.sorted { $0.measuredDate! < $1.measuredDate! }
            return MeasureSeries(name: name, unit: sorted.first?.unit ?? "",
                                 points: sorted.map { Point(at: $0.measuredDate!, value: $0.value!) })
        }
    }
}

// MARK: - Training

extension Analytics.Trends {
    public static func steps(_ d: Dashboard, now: Date) -> (days: [Column], average: Double, count: Int)? {
        var byDay: [String: Double?] = [:]
        for r in d.dailyHealth { byDay[r.day] = r.steps }
        let days = LogTime.lastDays(30, now: now).map { k in Column(key: k, value: byDay[k] ?? nil) }
        let vals = days.compactMap { $0.value }
        guard vals.count >= 3, let avg = Analytics.mean(vals) else { return nil }
        return (days, avg, vals.count)
    }
}

// MARK: - More: explorer, earn wall, summary

extension Analytics.Trends {
    public struct CatalogMetric: Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
    }

    public static let catalog = [
        CatalogMetric(id: "weight", label: "Weight (lb)"), CatalogMetric(id: "steps", label: "Steps"),
        CatalogMetric(id: "food_noise", label: "Food noise"), CatalogMetric(id: "mood", label: "Mood"),
        CatalogMetric(id: "energy", label: "Energy"), CatalogMetric(id: "sleep_quality", label: "Sleep quality"),
        CatalogMetric(id: "resting_hr", label: "Resting HR"), CatalogMetric(id: "calories", label: "Calories"),
        CatalogMetric(id: "protein_g", label: "Protein (g)"), CatalogMetric(id: "active_calories", label: "Active calories"),
        CatalogMetric(id: "exercise_minutes", label: "Exercise minutes"),
    ]

    /// dailySeries: one value a day for an explorer metric.
    public static func dailySeries(_ d: Dashboard, _ id: String) -> [String: Double] {
        var m: [String: Double] = [:]
        if id == "weight" {
            for w in Analytics.dailyWeight(Analytics.smoothWeights(d)) { m[w.day] = w.lb }
            return m
        }
        if id == "calories" || id == "protein_g" {
            for r in d.dailyTotals { if let v = id == "calories" ? r.calories : r.proteinG { m[r.date] = v } }
            return m
        }
        let fields: [String: KeyPath<Checkin, Double?>] = [
            "steps": \.steps, "food_noise": \.foodNoise, "mood": \.mood, "energy": \.energy, "sleep_quality": \.sleepQuality,
            "resting_hr": \.restingHr, "active_calories": \.activeCalories, "exercise_minutes": \.exerciseMinutes,
        ]
        if let f = fields[id] { for c in d.checkins { if let v = c[keyPath: f] { m[c.day] = v } } }
        if id == "steps" || id == "resting_hr" {
            let f: KeyPath<DailyHealth, Double?> = id == "steps" ? \.steps : \.restingHr
            for h in d.dailyHealth where m[h.day] == nil { if let v = h[keyPath: f] { m[h.day] = v } }
        }
        return m
    }

    public struct Pair: Hashable, Sendable, Identifiable {
        public var day: String
        public var x: Double
        public var y: Double
        public var id: String { day }
    }

    public static func alignedPair(_ a: [String: Double], _ b: [String: Double]) -> [Pair] {
        a.keys.filter { b[$0] != nil }.sorted().map { Pair(day: $0, x: a[$0]!, y: b[$0]!) }
    }

    public struct EarnCell: Hashable, Sendable, Identifiable {
        public var day: String
        public var earned: Bool?
        public var has: Bool
        public var isToday: Bool
        public var id: String { day }
    }

    /// earnDays: the last 8 weeks of Earn It marks.
    public static func earnDays(_ d: Dashboard, now: Date, weeks: Int = 8) -> [EarnCell] {
        var byDay: [String: Checkin] = [:]
        for c in d.checkins { byDay[c.day] = c }
        let today = LogTime.today(now)
        return LogTime.lastDays(weeks * 7, now: now).map { k in
            let row = byDay[k]
            return EarnCell(day: k, earned: row?.earned, has: row != nil, isToday: k == today)
        }
    }

    public struct SummaryTile: Hashable, Sendable, Identifiable {
        public var section: String
        public var label: String
        public var value: String
        public var sub: String
        public var spark: [Point]
        public var sparkFrom: Date
        public var sparkTo: Date
        public var id: String { label }
    }

    public static func summary(_ d: Dashboard, now: Date, calorieTarget: Double?, proteinTarget: Double?) -> [SummaryTile] {
        let today = LogTime.today(now)
        let t30 = now.addingTimeInterval(-30 * 86400)
        var tiles: [SummaryTile] = []

        let sm = Analytics.smoothWeights(d)
        let rate = Analytics.trendRate(sm, days: 28)
        tiles.append(SummaryTile(section: "weight", label: "Weight",
                                 value: sm.last.map { "\(num($0.trend, 1)) lb" } ?? "—",
                                 sub: rate.map { "\(signed($0, 1)) lb a week, 4-week trend" } ?? "Needs more weigh-ins",
                                 spark: sm.filter { $0.at >= t30 }.map { Point(at: $0.at, value: $0.trend) }, sparkFrom: t30, sparkTo: now))

        let week = LogTime.lastDays(7, now: now).compactMap { Analytics.totals(on: $0, d) }.filter { $0.calories != nil }
        let kcal = Analytics.mean(week.compactMap { $0.calories })
        let pro: Double? = week.isEmpty ? nil : week.reduce(0.0) { $0 + ($1.proteinG ?? 0) } / Double(week.count)
        let hits = proteinTarget.map { t in week.filter { ($0.proteinG ?? -1) >= t }.count }
        var foodSpark: [Point] = []
        for k in LogTime.lastDays(30, now: now) {
            if let c = Analytics.totals(on: k, d)?.calories { foodSpark.append(Point(key: k, value: c)) }
        }
        var foodSub = "Log meals to see averages"
        if kcal != nil {
            foodSub = "\(num(pro)) g protein a day"
            if let hits { foodSub += ", target hit \(hits) of \(week.count)" }
        }
        let foodValue = kcal.map { "\(num($0)) kcal" } ?? "Not logged"
        tiles.append(SummaryTile(section: "food", label: "Food, last 7 days", value: foodValue, sub: foodSub,
                                 spark: foodSpark.filter { $0.at >= t30 }, sparkFrom: t30, sparkTo: now))

        let m = maintenance(d, now: now)
        let mFrom = LogTime.noon(m.start).addingTimeInterval(-12 * 3600)
        tiles.append(SummaryTile(section: "food", label: "Maintenance",
                                 value: m.best.map { "\(num(($0 / 10).rounded() * 10)) kcal" } ?? "—",
                                 sub: m.fromLogs != nil ? "From food logs and weight" : m.watch != nil ? "Apple Watch estimate" : "Needs more data",
                                 spark: m.burn.filter { $0.at >= mFrom }, sparkFrom: mFrom, sparkTo: now))

        let level = LevelModel(d)
        let share = level.share(at: now)
        let next = Analytics.nextPlanned(d)
        let levelPts: [Point] = (0...13).reversed().compactMap { i in
            let at = now.addingTimeInterval(-Double(i) * 86400)
            return level.share(at: at).map { Point(at: at, value: $0) }
        }
        let lFrom = now.addingTimeInterval(-14 * 86400)
        var medSub = "Estimated level now"
        if let next {
            let word = Analytics.planIsOverdue(next, now: now) ? "Overdue" : "Next"
            medSub = "\(word): \(planDoseText(next)), \(LogTime.weekdayDate(LogTime.noon(next.plannedOn)))"
        }
        let medValue = share.map { "\(num($0 * 100))% of peak" } ?? "No doses yet"
        tiles.append(SummaryTile(section: "meds", label: "Medication", value: medValue, sub: medSub,
                                 spark: levelPts.count > 1 ? levelPts : [], sparkFrom: lFrom, sparkTo: now))

        let maps = signalMaps(d)
        var rec = offNormal(maps, key: today)
        if rec.checked.count < 2 { rec = offNormal(maps, key: LogTime.shift(today, -1)) }
        let rhr = d.dailyHealth.compactMap { r in r.restingHr.map { Point(key: r.day, value: $0) } }.filter { $0.at >= t30 }
        let recValue = rec.checked.count < 2 ? "—" : rec.off.count >= 2 ? "\(rec.off.count) of \(rec.checked.count) off" : "Normal"
        let recSub = rec.checked.count < 2 ? "Needs Apple Health data"
            : !rec.off.isEmpty ? rec.off.map { "\($0.def.lower) \($0.diffText)" }.joined(separator: ", ")
            : "\(rec.checked.count) signals in their usual range"
        tiles.append(SummaryTile(section: "body", label: "Recovery", value: recValue, sub: recSub,
                                 spark: rhr.count > 1 ? rhr : [], sparkFrom: t30, sparkTo: now))
        return tiles
    }
}

// MARK: - Export (prescriber CSV, JSON, print views)

extension Analytics.Trends {
    static func csvEscape(_ v: String?) -> String {
        guard let v else { return "" }
        if v.contains("\"") || v.contains(",") || v.contains("\n") { return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return v
    }

    /// A number the way JavaScript's String() writes it: 540, 32.5.
    static func raw(_ v: Double?) -> String? {
        guard let v, v.isFinite else { return nil }
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(v)
    }

    static func rawBool(_ v: Bool?) -> String? { v.map { $0 ? "true" : "false" } }

    static func csv(_ header: [String], _ rows: [[String?]]) -> String {
        let lines = [header.map { csvEscape($0) }.joined(separator: ",")] + rows.map { $0.map { csvEscape($0) }.joined(separator: ",") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// prescriberCSV: meals, weights, doses, check-ins, side effects and measurements.
    public static func prescriberCSV(_ d: Dashboard) -> String {
        var parts: [String] = ["MEALS"]
        parts.append(csv(["eaten_at", "meal_type", "item", "quantity", "calories", "protein_g", "carbs_g", "fat_g", "fiber_g", "notes"],
                         d.meals.map { m -> [String?] in [m.eatenAt, m.mealType, m.item, m.quantity, raw(m.calories), raw(m.proteinG), raw(m.carbsG), raw(m.fatG), raw(m.fiberG), m.notes] }))
        parts += ["", "WEIGHTS"]
        parts.append(csv(["measured_at", "weight_lb", "notes"], d.weights.map { w -> [String?] in [w.measuredAt, raw(w.weightLb), w.notes] }))
        parts += ["", "DOSES"]
        parts.append(csv(["taken_at", "compound", "dose_mg", "units", "site", "skipped", "notes"],
                         d.doses.map { x -> [String?] in [x.takenAt, x.compound, raw(x.doseMg), raw(x.units), x.site, rawBool(x.skipped), x.notes] }))
        parts += ["", "CHECKINS"]
        parts.append(csv(["day", "ate_vs_usual", "moved_vs_usual", "dose_feel", "mood", "food_noise", "energy", "sleep_quality", "sleep_hours",
                          "exercise_minutes", "steps", "resting_hr", "active_calories", "earned", "notes"],
                         d.checkins.map { c -> [String?] in
                             [c.day, c.ateVsUsual, c.movedVsUsual, c.doseFeel, raw(c.mood), raw(c.foodNoise), raw(c.energy), raw(c.sleepQuality), raw(c.sleepHours),
                              raw(c.exerciseMinutes), raw(c.steps), raw(c.restingHr), raw(c.activeCalories), rawBool(c.earned), c.notes]
                         }))
        parts += ["", "SIDE EFFECTS"]
        parts.append(csv(["recorded_on", "recorded_at", "effect", "severity", "notes"],
                         d.sideEffects.map { e -> [String?] in [e.recordedOn, e.recordedAt, e.effect, raw(e.severity), e.notes] }))
        parts += ["", "MEASUREMENTS"]
        parts.append(csv(["measured_at", "metric", "value", "unit", "notes"],
                         d.measurements.map { r -> [String?] in [r.measuredAt, r.metric, raw(r.value), r.unit, r.notes] }))
        return parts.joined(separator: "\n")
    }

    /// The whole payload as JSON with the payload's own snake_case keys.
    public static func exportJSON(_ d: Dashboard) -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return (try? e.encode(d)) ?? Data("{}".utf8)
    }

    static func html(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// prescriberPrint: the one-page report for the print sheet.
    public static func prescriberHTML(_ d: Dashboard, now: Date) -> String {
        let j = journey(d)
        func row(_ k: String, _ v: String) -> String { "<tr><th>\(k)</th><td>\(v)</td></tr>" }
        let meals = d.meals.map { m in
            "<tr><td>\(m.eatenDate.map(dateTime) ?? "")</td><td>\(html(m.mealType))</td><td>\(html(m.item))</td><td>\(raw(m.calories) ?? "")</td><td>\(raw(m.proteinG) ?? "")</td></tr>"
        }.joined()
        let doses = d.doses.map { x in
            "<tr><td>\(x.takenDate.map(LogTime.weekdayDate) ?? "")</td><td>\(html(x.compound))</td><td>\(x.skipped == true ? "skipped" : raw(x.doseMg) ?? "")</td><td>\(html(x.site))</td></tr>"
        }.joined()
        let summary = [
            row("Verdict", verdictLabel(d, now: now)),
            row("Current weight", j.map { "\(num($0.current.lb, 1)) lb" } ?? "—"),
            row("Start weight", j.map { "\(num($0.startLb, 1)) lb" } ?? "—"),
            row("Goal", j?.goalLb.map { "\(num($0, 1)) lb" } ?? "—"),
            row("Change since start", j.map { "\(num($0.changeStart, 1)) lb" } ?? "—"),
            row("Change since tirzepatide", j.map { "\(num($0.changeTirz, 1)) lb" } ?? "—"),
        ].joined()
        return """
        <!DOCTYPE html><html><head><title>Log prescriber report</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #111; padding: 24px; }
          h1 { margin: 0 0 4px; }
          .muted { color: #555; }
          table { border-collapse: collapse; width: 100%; margin: 16px 0; }
          th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
          th { width: 30%; color: #555; font-weight: 600; }
        </style></head><body>
        <h1>Health log</h1>
        <p class="muted">Prescriber report · generated \(dateTime(now)) · times in \(LogTime.zone.identifier)</p>
        <h2>Summary</h2>
        <table>\(summary)</table>
        <h2>Doses</h2>
        <table><tr><th>Date</th><th>Compound</th><th>Dose</th><th>Site</th></tr>\(doses.isEmpty ? "<tr><td colspan=4>None</td></tr>" : doses)</table>
        <h2>Meals</h2>
        <table><tr><th>When</th><th>Type</th><th>Item</th><th>Cal</th><th>Protein</th></tr>\(meals.isEmpty ? "<tr><td colspan=5>None</td></tr>" : meals)</table>
        <p class="muted">Drug level is an estimate from half-life, not a lab measurement. Meal macros may be estimates.</p>
        </body></html>
        """
    }

    /// coachPackWindow: the last 28 days on one page, for a doctor.
    public static func coachPackHTML(_ d: Dashboard, now: Date, proteinTarget: Double?) -> String {
        let toKey = LogTime.today(now)
        let fromKey = LogTime.shift(toKey, -27)
        func inWin(_ k: String?) -> Bool { guard let k else { return false }; return k >= fromKey && k <= toKey }
        let j = journey(d)
        let weights = Analytics.smoothWeights(d).filter { inWin($0.day) }
        let foodDays = d.dailyTotals.filter { inWin($0.date) && $0.proteinG != nil }
        let hits = proteinTarget.map { t in foodDays.filter { ($0.proteinG ?? 0) >= t }.count }
        let avgPro = Analytics.mean(foodDays.compactMap { $0.proteinG })
        let thoughts = d.foodThoughts.filter { inWin($0.thoughtDate.map(LogTime.dayKey)) }
        let strong = thoughts.filter { ($0.strength ?? 0) >= 2 }.count
        let effects = d.sideEffects.filter { inWin($0.recordedOn) }
        let doses = d.doses.filter { inWin($0.takenDate.map(LogTime.dayKey)) }
        func row(_ k: String, _ v: String) -> String { "<tr><th>\(k)</th><td>\(v)</td></tr>" }
        var weightText = "No weigh-ins in this window"
        if let a = weights.first?.lb, let b = weights.last?.lb {
            weightText = "\(num(a, 1)) → \(num(b, 1)) lb (\(signed(b - a)) lb, \(weights.count) weigh-ins)"
        }
        var proteinText = "No food logged"
        if let hits, let t = proteinTarget { proteinText = "\(hits) of \(foodDays.count) logged days at \(num(t)) g or more" }
        else if !foodDays.isEmpty { proteinText = "Average \(num(avgPro)) g; no protein target set" }
        let summary = [
            row("Current weight", j.map { "\(num($0.current.lb, 1)) lb" } ?? "—"),
            row("Weight in this window", weightText),
            row("Protein hit rate", proteinText),
            row("Food thoughts", thoughts.isEmpty ? "None logged" : "\(thoughts.count) logged, \(strong) strong pull or craving"),
            row("Side effects", effects.isEmpty ? "None logged" : "\(effects.count) logged"),
            row("Doses", doses.isEmpty ? "None logged" : "\(doses.count) in this window"),
        ].joined()
        let doseRows = doses.map { x in
            "<tr><td>\(x.takenDate.map(LogTime.weekdayDate) ?? "")</td><td>\(html(x.compound))</td><td>\(x.skipped == true ? "skipped" : raw(x.doseMg) ?? raw(x.units) ?? "")</td><td>\(html(x.site))</td></tr>"
        }.joined()
        let effectRows = effects.map { e in
            "<tr><td>\(short(e.recordedOn))</td><td>\(html(e.effect))</td><td>\(raw(e.severity) ?? "")</td><td>\(html(e.notes))</td></tr>"
        }.joined()
        let none = "<tr><td colspan=4>None in this window</td></tr>"
        return """
        <!DOCTYPE html><html><head><title>Log 4-week coach pack</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #111; padding: 24px; max-width: 740px; }
          h1 { margin: 0 0 4px; font-size: 24px; }
          h2 { margin: 22px 0 6px; font-size: 16px; }
          .muted { color: #555; margin: 0 0 16px; }
          table { border-collapse: collapse; width: 100%; margin: 8px 0 0; }
          th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #ddd; vertical-align: top; font-size: 13px; }
          table.kv th { width: 40%; color: #555; font-weight: 600; }
        </style></head><body>
        <h1>4-week coach pack</h1>
        <p class="muted">\(short(fromKey)) to \(short(toKey)) · generated \(dateTime(now)) · \(LogTime.zone.identifier)</p>
        <h2>Summary</h2>
        <table class="kv">\(summary)</table>
        <h2>Doses</h2>
        <table><tr><th>Date</th><th>Compound</th><th>Dose</th><th>Site</th></tr>\(doseRows.isEmpty ? none : doseRows)</table>
        <h2>Side effects</h2>
        <table><tr><th>Date</th><th>Effect</th><th>Severity</th><th>Notes</th></tr>\(effectRows.isEmpty ? none : effectRows)</table>
        <p class="muted">Meal macros may be estimates. Drug level is not included. This pack covers the last 28 days only.</p>
        </body></html>
        """
    }
}
