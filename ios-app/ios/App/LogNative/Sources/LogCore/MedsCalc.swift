import Foundation

// Meds-tab calculations, ported from the original web app (removed Nov 2026): plannedDoses, levelPoints, siteRotation,
// vialRunway, titrationHistory (analytics.js), planRows, planSteps (signals.js),
// firstRetaDose, compoundRunway (focus.js) and siteLabel (app.js). retaSwitchAt is the
// shared Analytics function. Results match the web app on the same data; MedsTests
// checks them against the made-up fixture.

/// One shot for the level model: a time, an amount and a compound.
public struct Shot: Hashable, Sendable {
    public var at: Date
    public var mg: Double
    public var compound: String?
    public var planned: Bool
    public init(at: Date, mg: Double, compound: String?, planned: Bool = false) {
        self.at = at; self.mg = mg; self.compound = compound; self.planned = planned
    }
}

/// A modeled level at a time.
public struct LevelSample: Hashable, Sendable, Identifiable {
    public var id: Int
    public var t: Date
    public var v: Double
}

public struct LevelPoints: Sendable {
    /// From the logged doses only.
    public var logged: [LevelSample]
    /// With the next planned shot added (same times).
    public var withNext: [LevelSample]
    public var start: Date
    public var end: Date
}

public struct SiteRotation: Sendable {
    /// The last dose that had a site (not skipped).
    public var last: Dose?
    public var lastSite: String?
    /// The suggested next site.
    public var next: String?
    /// When each site was last used.
    public var lastUsed: [String: Date]
}

public struct TitrationStep: Sendable, Identifiable {
    public var id: Int
    public var dose: Dose
    /// nil when skipped.
    public var mg: Double?
    /// The first step, or a change of compound, amount or skipped.
    public var changed: Bool
}

public struct PlanStep: Hashable, Sendable {
    public var compound: String?
    public var doseMg: Double
    public var units: Double?
    public var from: String
    public var to: String
    public var weeks: Int
}

public struct VialItem: Sendable {
    public var vial: Vial
    public var weeks: Double?
    public var until: Date?
}

public struct VialRunway: Sendable {
    public var ready: Bool
    public var summary: String
    public var items: [VialItem]
    public var soonest: VialItem?
}

public struct CompoundRunway: Sendable {
    public var ready: Bool
    public var items: [VialItem]
    public var mg: Double?
    public var units: Double?
    public var weeks: Double?
    public var weeklyMg: Double?
    public var weeklyUnits: Double?
}

extension Analytics {

    // MARK: Level model

    /// Modeled mg in the body at `at` from these shots.
    public static func remaining(at: Date, shots: [Shot], protocols: [ProtocolRow]) -> Double {
        var total = 0.0
        for s in shots where at >= s.at {
            let days = at.timeIntervalSince(s.at) / 86400
            total += s.mg * pow(0.5, days / halfLifeDays(s.compound, protocols: protocols))
        }
        return total
    }

    /// Doses that count (not skipped, with a time and mg), in payload order.
    public static func realShots(_ doses: [Dose]) -> [Shot] {
        doses.compactMap { (d: Dose) -> Shot? in
            guard d.skipped != true, let t = d.takenDate, let mg = d.doseMg else { return nil }
            return Shot(at: t, mg: mg, compound: d.compound)
        }
    }

    /// The logged shots plus the next weekly shot if it falls before the retatrutide switch
    /// (web: plannedDoses). Its amount is the active protocol's dose, else the last dose, else 3 mg.
    public static func plannedShots(_ doses: [Dose], protocols: [ProtocolRow]) -> (list: [Shot], next: Date?, withNext: [Shot]) {
        let list = realShots(doses)
        guard let last = list.last else { return (list, nil, list) }
        let next = last.at.addingTimeInterval(7 * 86400)
        if next >= LogTime.retaStart { return (list, nil, list) }
        let active = protocols.first { $0.status == "active" }
        var plannedMg = last.mg
        if let a = active?.typicalDoseMg, a != 0 { plannedMg = a }
        if plannedMg == 0 { plannedMg = 3 }
        let planned = Shot(at: next, mg: plannedMg, compound: last.compound ?? "tirzepatide", planned: true)
        return (list, next, list + [planned])
    }

    /// The level on a real time axis every `stepHours`, from the first dose to two weeks after the
    /// switch, plus each shot's instant (and a minute before) so peaks are sharp. nil with no doses.
    public static func levelPoints(_ d: Dashboard, stepHours: Double = 6) -> LevelPoints? {
        let real = realShots(d.doses)
        guard let first = real.first else { return nil }
        let planned = plannedShots(d.doses, protocols: d.protocols).withNext
        let start = first.at
        let end = LogTime.retaStart.addingTimeInterval(14 * 86400)
        let step = stepHours * 3600
        var times = Set<Double>()
        var t = start.timeIntervalSince1970
        while t <= end.timeIntervalSince1970 { times.insert(t); t += step }
        for s in planned {
            let st = s.at.timeIntervalSince1970
            if st > start.timeIntervalSince1970 && st <= end.timeIntervalSince1970 {
                times.insert(st - 60)
                times.insert(st)
            }
        }
        let sorted = times.sorted()
        var logged: [LevelSample] = []
        var withNext: [LevelSample] = []
        logged.reserveCapacity(sorted.count)
        withNext.reserveCapacity(sorted.count)
        for (i, ts) in sorted.enumerated() {
            let at = Date(timeIntervalSince1970: ts)
            logged.append(LevelSample(id: i, t: at, v: remaining(at: at, shots: real, protocols: d.protocols)))
            withNext.append(LevelSample(id: i, t: at, v: remaining(at: at, shots: planned, protocols: d.protocols)))
        }
        return LevelPoints(logged: logged, withNext: withNext, start: start, end: end)
    }

    // MARK: Sites

    /// Last site, suggested next site and when each site was last used (web: siteRotation).
    public static func siteRotation(_ d: Dashboard) -> SiteRotation {
        let doses = d.doses.filter { $0.skipped != true && !($0.site ?? "").isEmpty }
            .sorted { ($0.takenDate ?? .distantPast) < ($1.takenDate ?? .distantPast) }
        let last = doses.last
        let lastSite = last?.site
        var next = d.protocols.first(where: { $0.status == "active" })?.nextSite
        if next?.isEmpty ?? true { next = nil }
        if next == nil, let ls = lastSite, let i = Sites.all.firstIndex(of: ls) {
            next = Sites.all[(i + 1) % Sites.all.count]
        }
        var lastUsed: [String: Date] = [:]
        for dose in doses {
            if let s = dose.site, let t = dose.takenDate { lastUsed[s] = t }
        }
        return SiteRotation(last: last, lastSite: lastSite, next: next, lastUsed: lastUsed)
    }

    /// A dose's site as words, from `site` or a "site X;" note (web: siteLabel). "—" if none.
    public static func siteLabel(_ dose: Dose) -> String {
        var key = (dose.site ?? "").trimmingCharacters(in: .whitespaces)
        if key.isEmpty, let notes = dose.notes,
           let r = notes.range(of: #"site\s+([^;]+)"#, options: [.regularExpression, .caseInsensitive]) {
            let match = String(notes[r])
            key = match.replacingOccurrences(of: #"^site\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        }
        if key.isEmpty { return "—" }
        return Sites.labels[key] ?? key
    }

    // MARK: Titration and plan

    /// Every dose in time order, marking the first and each change (web: titrationHistory).
    public static func titrationHistory(_ doses: [Dose]) -> [TitrationStep] {
        let list = doses.filter { $0.takenDate != nil }.sorted { $0.takenDate! < $1.takenDate! }
        var steps: [TitrationStep] = []
        var prev: (compound: String?, mg: Double?, skipped: Bool)?
        for (i, d) in list.enumerated() {
            let skipped = d.skipped == true
            let mg: Double? = skipped ? nil : d.doseMg
            var changed = true
            if let p = prev {
                changed = p.compound != d.compound || p.mg != mg || p.skipped != skipped
            }
            steps.append(TitrationStep(id: i, dose: d, mg: mg, changed: changed))
            prev = (d.compound, mg, skipped)
        }
        return steps
    }

    /// Planned rows with an amount, by date (web: planRows).
    public static func planRows(_ d: Dashboard) -> [DosePlanRow] {
        d.dosePlan.filter { !$0.plannedOn.isEmpty && $0.doseMg != nil }.sorted { $0.plannedOn < $1.plannedOn }
    }

    /// Consecutive weeks at the same compound and amount form a step (web: planSteps).
    public static func planSteps(_ rows: [DosePlanRow]) -> [PlanStep] {
        var steps: [PlanStep] = []
        for r in rows {
            guard let mg = r.doseMg else { continue }
            if var last = steps.last, last.compound == r.compound, last.doseMg == mg {
                last.to = r.plannedOn
                last.weeks += 1
                steps[steps.count - 1] = last
            } else {
                steps.append(PlanStep(compound: r.compound, doseMg: mg, units: r.units, from: r.plannedOn, to: r.plannedOn, weeks: 1))
            }
        }
        return steps
    }

    // MARK: Switch

    public static func protocolRow(_ d: Dashboard, _ compound: String) -> ProtocolRow? {
        d.protocols.first { ($0.compound ?? "").lowercased() == compound }
    }

    public static func firstRetaDose(_ d: Dashboard) -> Dose? {
        d.doses.filter { $0.skipped != true && $0.takenDate != nil && ($0.compound ?? "").lowercased() == "retatrutide" }
            .min { $0.takenDate! < $1.takenDate! }
    }

    // MARK: Vials

    /// Each vial's runway at its own compound's weekly dose (web: vialRunway).
    public static func vialRunway(_ d: Dashboard, now: Date = Date()) -> VialRunway {
        guard !d.vials.isEmpty else {
            return VialRunway(ready: false, summary: "Add a vial to see inventory and supply runway.", items: [], soonest: nil)
        }
        let items: [VialItem] = d.vials.map { (v: Vial) -> VialItem in
            let proto = d.protocols.first { $0.compound == v.compound }
            let weeklyMg = proto?.typicalDoseMg
            let weeklyUnits = proto?.units
            var weeks: Double?
            if let w = weeklyMg, w != 0, let rem = v.remainingMg { weeks = rem / w }
            else if let w = weeklyUnits, w != 0, let rem = v.remainingUnits { weeks = rem / w }
            let until = weeks.map { now.addingTimeInterval($0 * 7 * 86400) }
            return VialItem(vial: v, weeks: weeks, until: until)
        }
        let soonest = items.filter { $0.until != nil }.min { $0.until! < $1.until! }
        return VialRunway(ready: true, summary: "", items: items, soonest: soonest)
    }

    /// On-hand totals and weeks of supply for one compound (web: compoundRunway).
    public static func compoundRunway(_ d: Dashboard, _ compound: String, now: Date = Date()) -> CompoundRunway {
        let r = vialRunway(d, now: now)
        let none = CompoundRunway(ready: false, items: [], mg: nil, units: nil, weeks: nil, weeklyMg: nil, weeklyUnits: nil)
        guard r.ready else { return none }
        let items = r.items.filter { ($0.vial.compound ?? "").lowercased() == compound }
        guard !items.isEmpty else { return none }
        let proto = protocolRow(d, compound)
        let weeklyMg = proto?.typicalDoseMg
        let weeklyUnits = proto?.units
        var mg = 0.0, units = 0.0
        var hasMg = false, hasUnits = false
        for i in items {
            if let m = i.vial.remainingMg ?? i.vial.totalMg { mg += m; hasMg = true }
            if let u = i.vial.remainingUnits ?? i.vial.totalUnits { units += u; hasUnits = true }
        }
        var weeks: Double?
        if let w = weeklyMg, w != 0, hasMg { weeks = mg / w }
        else if let w = weeklyUnits, w != 0, hasUnits { weeks = units / w }
        return CompoundRunway(ready: true, items: items, mg: hasMg ? mg : nil, units: hasUnits ? units : nil,
                              weeks: weeks, weeklyMg: weeklyMg, weeklyUnits: weeklyUnits)
    }
}
