import Foundation

extension Dose {
    /// GLP-1 shots (tirzepatide, retatrutide, or an old row with no compound). Everything else,
    /// such as daily tesamorelin, is a peptide dose and stays out of the GLP-1 math.
    public static func isGLP1(_ compound: String?) -> Bool {
        guard let c = compound?.lowercased(), !c.isEmpty else { return true }
        return c == "tirzepatide" || c == "retatrutide" || c == "semaglutide"
    }
}

/// A repeating peptide schedule (log.regimen): a compound, a dose, how often, from and to.
/// every_days 1 = daily, 7 = weekly. days_on / days_off = a cycle such as 5 on, 2 off.
public struct Regimen: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var compound: String?
    public var displayName: String?
    @Flex public var doseMg: Double?
    @Flex public var units: Double?
    @Flex public var everyDays: Double?
    @Flex public var daysOn: Double?
    @Flex public var daysOff: Double?
    public var timeOfDay: String?
    public var startOn: String?
    public var endOn: String?
    @Flex public var concentrationMgPerMl: Double?
    public var sites: String?
    public var status: String?
    public var notes: String?

    public var name: String {
        if let n = displayName, !n.isEmpty { return n }
        let c = compound ?? "Peptide"
        return c.prefix(1).uppercased() + c.dropFirst()
    }

    /// "daily", "every 2 days", "weekly", "5 days on, 2 off"
    public var frequencyText: String {
        if let on = daysOn.map(Int.init), let off = daysOff.map(Int.init), on > 0, off > 0 {
            return "\(on) days on, \(off) off"
        }
        switch Int(everyDays ?? 1) {
        case 1: return "daily"
        case 7: return "weekly"
        case let n: return "every \(n) days"
        }
    }

    /// Units to draw on a U-100 syringe: the stored value, else from the mix strength.
    public var drawUnits: Double? {
        if let units { return units }
        if let doseMg, let c = concentrationMgPerMl, c > 0 { return doseMg / c * 100 }
        return nil
    }

    public func isDoseDay(_ day: String) -> Bool {
        guard let start = startOn.map({ String($0.prefix(10)) }), day >= start else { return false }
        if let end = endOn.map({ String($0.prefix(10)) }), day > end { return false }
        if status == "paused" || status == "done" { return false }
        let n = LogTime.dayDiff(day, start)
        if let on = daysOn.map(Int.init), let off = daysOff.map(Int.init), on > 0, off > 0 {
            return n % (on + off) < on
        }
        let every = max(1, Int(everyDays ?? 1))
        return n % every == 0
    }
}

/// Where a regimen stands on a given day.
public struct RegimenStatus: Hashable, Sendable {
    public var regimen: Regimen
    /// Days until the first shot (0 when it has started).
    public var daysToStart: Int
    /// A shot is planned today.
    public var dueToday: Bool
    /// Today's shot is already logged (taken or skipped).
    public var loggedToday: Bool
    /// The next planned day from today on (today included if not logged yet).
    public var nextDay: String?
    /// Day number in the course and how many planned shots in total, when it has an end date.
    public var shotNumber: Int?
    public var totalShots: Int?
    /// Shots logged (not skipped) since the start.
    public var taken: Int
    /// Planned days before today with nothing logged, in the last 14 days.
    public var missedRecently: Int
    public var finished: Bool
}

extension Analytics {
    /// Status for every regimen that hasn't ended more than a week ago, soonest first.
    public static func regimenStatuses(_ d: Dashboard, now: Date = Date()) -> [RegimenStatus] {
        let today = LogTime.today(now)
        return d.regimens.compactMap { r -> RegimenStatus? in
            guard let start = r.startOn.map({ String($0.prefix(10)) }) else { return nil }
            let end = r.endOn.map { String($0.prefix(10)) }
            if let end, LogTime.dayDiff(today, end) > 7 { return nil }
            let compound = (r.compound ?? "").lowercased()
            let mine = d.peptideDoses.filter { ($0.compound ?? "").lowercased() == compound }
            let loggedDays = Set(mine.compactMap { $0.takenDate.map(LogTime.dayKey) })
            let dueToday = r.isDoseDay(today)
            let loggedToday = loggedDays.contains(today)
            var next: String?
            var day = (dueToday && !loggedToday) ? today : LogTime.shift(today, 1)
            if day < start { day = start }
            for _ in 0..<60 {
                if let end, day > end { break }
                if r.isDoseDay(day) { next = day; break }
                day = LogTime.shift(day, 1)
            }
            var total: Int?
            if let end {
                var n = 0
                var k = start
                while k <= end { if r.isDoseDay(k) { n += 1 }; k = LogTime.shift(k, 1) }
                total = n
            }
            var number: Int?
            if today >= start {
                var n = 0
                var k = start
                while k <= today { if r.isDoseDay(k) { n += 1 }; k = LogTime.shift(k, 1) }
                number = n
            }
            var missed = 0
            for back in 1...14 {
                let k = LogTime.shift(today, -back)
                if k >= start && r.isDoseDay(k) && !loggedDays.contains(k) { missed += 1 }
            }
            let finished = end.map { today > $0 } ?? false
            return RegimenStatus(regimen: r, daysToStart: max(0, LogTime.dayDiff(start, today)), dueToday: dueToday,
                                 loggedToday: loggedToday, nextDay: next, shotNumber: number, totalShots: total,
                                 taken: mine.filter { $0.skipped != true }.count, missedRecently: missed, finished: finished)
        }
        .sorted { ($0.nextDay ?? "9999") < ($1.nextDay ?? "9999") }
    }

    /// The belly spot for a daily peptide's next shot: rotates through the four belly sites,
    /// starting after the one used last for that compound.
    public static func nextBellySite(_ d: Dashboard, compound: String) -> String {
        let belly = ["Abd UR", "Abd LR", "Abd LL", "Abd UL"]
        let last = d.peptideDoses
            .filter { ($0.compound ?? "").lowercased() == compound.lowercased() && $0.skipped != true }
            .compactMap { dose -> (Date, String)? in
                guard let t = dose.takenDate, let s = dose.site, belly.contains(s) else { return nil }
                return (t, s)
            }
            .max { $0.0 < $1.0 }?.1
        guard let last, let i = belly.firstIndex(of: last) else { return belly[0] }
        return belly[(i + 1) % belly.count]
    }
}
