import Foundation
import LogCore

// What each Trends section shows, worked out once per payload (keyed by store.dataTime and the
// day) rather than on every render. Interactive choices (ranges, compare-with, explorer metrics)
// only filter these.

/// Built sections, thrown away when the data or the day changes.
final class TrendsCache {
    var stamp = ""
    var built: [String: Any] = [:]

    func get<T>(_ key: String, stamp: String, _ build: () -> T) -> T {
        if stamp != self.stamp {
            self.stamp = stamp
            built.removeAll()
        }
        if let v = built[key] as? T { return v }
        let v = build()
        built[key] = v
        return v
    }
}

struct TrSection: Identifiable, Hashable {
    var id: String
    var label: String
    static let all = [
        TrSection(id: "summary", label: "Summary"), TrSection(id: "ask", label: "Ask"), TrSection(id: "weight", label: "Weight"), TrSection(id: "food", label: "Food"),
        TrSection(id: "meds", label: "Meds"), TrSection(id: "body", label: "Body"), TrSection(id: "training", label: "Training"),
        TrSection(id: "more", label: "More"),
    ]
}

struct TrTargets {
    var calories: Double?
    var protein: Double?
}

// MARK: - Weight

struct TrWeightModel {
    var now: Date
    var sm: [WeightPoint]
    var byTime: [Date: WeightPoint]
    var goal: Double?
    var proj: TrendsCalc.Projection?
    var pace: TrendsCalc.Pace?
    var loss: TrendsCalc.LossRate?
    var glp1: Date
    var reta: Date
    var overlays: [String: [String: Double]]
    var recent: [[String]]
    var progress: WeightProgress.Summary?
    /// First weigh-in after a long gap, when Apple Health brought in years-old history.
    var recentStart: Date?

    init(_ d: Dashboard, now: Date) {
        self.now = now
        sm = Analytics.smoothWeights(d)
        var map: [Date: WeightPoint] = [:]
        for w in sm { map[w.at] = w }
        byTime = map
        goal = d.profile?.goalWeightLb
        proj = TrendsCalc.weightProjection(sm)
        pace = TrendsCalc.recentPace(sm, days: 28)
        loss = TrendsCalc.lossRate(sm)
        glp1 = TrendsCalc.firstGlp1At(d)
        reta = TrendsCalc.retaSwitchAt(d)
        var ov: [String: [String: Double]] = [:]
        for o in TrOverlay.all where o.id != "none" { ov[o.id] = TrendsCalc.overlayDaily(d, o.id, now: now) }
        overlays = ov
        recentStart = WeightProgress.recentStart(sm)
        progress = WeightProgress.make(sm, startLb: d.profile?.startWeightLb, goalLb: d.profile?.goalWeightLb, since: glp1, now: now)
        recent = sm.reversed().prefix(30).map { w in
            ["\(LogTime.weekdayDate(w.at)), \(LogTime.calendar.component(.year, from: w.at))", TrendsCalc.num(w.lb, 1), TrendsCalc.num(w.trend, 1)]
        }
    }
}

/// The compare-with series under the weight chart.
struct TrOverlay: Identifiable, Hashable {
    var id: String
    var label: String
    var title: String
    var color: String
    var zero: Bool

    static let all = [
        TrOverlay(id: "none", label: "Off", title: "", color: "s1", zero: false),
        TrOverlay(id: "calories", label: "Cal", title: "Calories", color: "s2", zero: true),
        TrOverlay(id: "steps", label: "Steps", title: "Steps", color: "s4", zero: true),
        TrOverlay(id: "sleep", label: "Sleep", title: "Sleep", color: "s3", zero: true),
        TrOverlay(id: "rhr", label: "RHR", title: "Resting heart rate", color: "s3", zero: false),
        TrOverlay(id: "hrv", label: "HRV", title: "HRV", color: "s4", zero: false),
        TrOverlay(id: "thoughts", label: "Thoughts", title: "Food thoughts", color: "s2", zero: false),
        TrOverlay(id: "noise", label: "Noise", title: "Food noise", color: "s3", zero: false),
    ]

    func text(_ v: Double) -> String {
        switch id {
        case "calories": return "\(TrendsCalc.num(v)) kcal"
        case "steps": return "\(TrendsCalc.num(v)) steps"
        case "sleep": return "\(TrendsCalc.num(v, 1)) h sleep"
        case "rhr": return "\(TrendsCalc.num(v)) bpm resting"
        case "hrv": return "\(TrendsCalc.num(v)) ms HRV"
        case "thoughts": return "\(TrendsCalc.num(v)) food thought\(v == 1 ? "" : "s")"
        default: return "\(TrendsCalc.num(v, 1)) food noise"
        }
    }

    func axis(_ v: Double) -> String {
        switch id {
        case "sleep": return "\(TrendsCalc.num(v))h"
        case "noise": return TrendsCalc.num(v, 1)
        case "thoughts": return TrendsCalc.num(v)
        default:
            if v >= 1000 { return "\(TrendsCalc.num(v / 1000, v.truncatingRemainder(dividingBy: 1000) != 0 ? 1 : 0))k" }
            return TrendsCalc.num(v)
        }
    }
}

struct TrRange: Identifiable, Hashable {
    var id: String
    var label: String
    var days: Double?
    var a11y: String

    static let all = [
        TrRange(id: "1m", label: "1M", days: 30, a11y: "1M"), TrRange(id: "3m", label: "3M", days: 91, a11y: "3M"),
        TrRange(id: "1y", label: "1Y", days: 365, a11y: "1Y"), TrRange(id: "all", label: "All", days: nil, a11y: "All"),
        TrRange(id: "glp1", label: "GLP-1", days: nil, a11y: "Since GLP-1"),
    ]
}

struct TrSummaryModel {
    var tiles: [TrendsCalc.SummaryTile]
    var weight: TrWeightModel
}

struct TrWeightSection {
    var weight: TrWeightModel
    var stall: TrendsCalc.Stall
    var body: TrendsCalc.BodyComp
}

// MARK: - Food

struct TrFoodModel {
    var trends: TrendsCalc.FoodTrends
    var maintenance: TrendsCalc.Maintenance
    var calorieTarget: Double?
    var protein: TrendsCalc.ProteinCard?
    var thoughts: TrendsCalc.ThoughtsCard?

    init(_ d: Dashboard, now: Date, targets: TrTargets) {
        trends = TrendsCalc.foodTrends(d, now: now, calorieTarget: targets.calories, proteinTarget: targets.protein)
        maintenance = TrendsCalc.maintenance(d, now: now)
        calorieTarget = targets.calories
        protein = TrendsCalc.proteinCard(d, now: now, target: targets.protein)
        thoughts = TrendsCalc.thoughtsCard(d, now: now)
    }
}

// MARK: - Meds

struct TrMedsModel {
    var shotWeek: [TrendsCalc.WeekRow]?
    var appetite: TrendsCalc.Appetite?
    var reta: TrendsCalc.RetaVsTirz
    var recaps: [TrendsCalc.CycleRecap]
    var feel: TrendsCalc.FeelReport
    var wearOff: TrendsCalc.WearOff
    var effects: [SideEffect]

    init(_ d: Dashboard, now: Date) {
        shotWeek = TrendsCalc.shotWeek(d, now: now)
        appetite = TrendsCalc.appetite(d, now: now)
        reta = TrendsCalc.retaVsTirz(d, now: now)
        recaps = TrendsCalc.cycleRecaps(d, now: now)
        feel = TrendsCalc.feelReport(d)
        wearOff = TrendsCalc.wearOff(d, now: now)
        effects = Array(d.sideEffects.reversed())
    }
}

// MARK: - Body

/// A row of "More from Apple Health".
struct TrHealthDef: Hashable {
    enum Style { case plain, minutes, mood, height }
    var id: String
    var label: String
    var unit: String = ""
    var digits: Int = 0
    var pair: String? = nil
    var style: Style = .plain

    static let groups: [(String, [TrHealthDef])] = [
        ("Heart and breathing", [
            TrHealthDef(id: "heart_rate_avg", label: "Heart rate, daily average", unit: "bpm"),
            TrHealthDef(id: "heart_rate_min", label: "Lowest heart rate", unit: "bpm"),
            TrHealthDef(id: "heart_rate_max", label: "Highest heart rate", unit: "bpm"),
            TrHealthDef(id: "respiratory_rate", label: "Breathing rate", unit: "/min", digits: 1),
            TrHealthDef(id: "spo2_avg", label: "Blood oxygen", unit: "%"),
            TrHealthDef(id: "spo2_min", label: "Lowest blood oxygen", unit: "%"),
            TrHealthDef(id: "bp_systolic", label: "Blood pressure", unit: "mmHg", pair: "bp_diastolic"),
        ]),
        ("Sleep", [
            TrHealthDef(id: "sleep_in_bed_h", label: "Time in bed", unit: "h", digits: 1),
            TrHealthDef(id: "sleep_core_min", label: "Core sleep", style: .minutes),
            TrHealthDef(id: "sleep_deep_min", label: "Deep sleep", style: .minutes),
            TrHealthDef(id: "sleep_rem_min", label: "REM sleep", style: .minutes),
            TrHealthDef(id: "sleep_awake_min", label: "Awake during the night", style: .minutes),
            TrHealthDef(id: "wrist_temp_f", label: "Wrist temperature while asleep", unit: "°F", digits: 1),
        ]),
        ("Energy and food", [
            TrHealthDef(id: "total_kcal", label: "Total energy burned", unit: "kcal"),
            TrHealthDef(id: "basal_kcal", label: "Resting energy", unit: "kcal"),
            TrHealthDef(id: "dietary_kcal", label: "Calories logged in Health", unit: "kcal"),
            TrHealthDef(id: "water_oz", label: "Water", unit: "fl oz"),
        ]),
        ("Activity", [
            TrHealthDef(id: "flights", label: "Flights climbed"),
            TrHealthDef(id: "cycling_mi", label: "Cycling distance", unit: "mi", digits: 1),
            TrHealthDef(id: "mindful_min", label: "Mindful minutes", unit: "min"),
        ]),
        ("Other", [
            TrHealthDef(id: "glucose_avg", label: "Blood glucose, average", unit: "mg/dL"),
            TrHealthDef(id: "glucose_min", label: "Lowest blood glucose", unit: "mg/dL"),
            TrHealthDef(id: "glucose_max", label: "Highest blood glucose", unit: "mg/dL"),
            TrHealthDef(id: "body_temp_f", label: "Body temperature", unit: "°F", digits: 1),
            TrHealthDef(id: "basal_temp_f", label: "Basal body temperature", unit: "°F", digits: 1),
            TrHealthDef(id: "state_of_mind", label: "Mood, from −1 to +1", style: .mood),
            TrHealthDef(id: "height_in", label: "Height", style: .height),
        ]),
    ]

    /// metricParts: the number and its unit.
    func parts(_ v: Double, _ pairV: Double?) -> (String, String) {
        switch style {
        case .minutes:
            let m = Int(v.rounded())
            if m < 60 { return (String(m), "min") }
            return ("\(m / 60) h \(m % 60)", "min")
        case .mood:
            return (TrendsCalc.signed(v, 2), "")
        case .height:
            return ("\(Int((v / 12).rounded(.down)))′\(TrendsCalc.num(v.truncatingRemainder(dividingBy: 12)))″", "")
        case .plain:
            if let pairV { return ("\(TrendsCalc.num(v, digits))/\(TrendsCalc.num(pairV, digits))", unit) }
            return (TrendsCalc.num(v, digits), unit)
        }
    }

    /// metricText: "72 bpm", "97%", "7 h 5 min"
    func text(_ v: Double, _ pairV: Double?) -> String {
        let (a, b) = parts(v, pairV)
        if b.isEmpty { return a }
        return ["%", "°F", "/min"].contains(b) ? a + b : a + "\u{00a0}" + b
    }

    func axis(_ v: Double) -> String {
        switch style {
        case .minutes: return v >= 60 ? "\(TrendsCalc.num(v / 60, 1)) h" : "\(Int(v.rounded())) min"
        case .mood: return TrendsCalc.signed(v, 1)
        case .height: return "\(TrendsCalc.num(v, 1)) in"
        case .plain: return TrendsCalc.num(v, abs(v - v.rounded()) < 1e-6 ? 0 : max(1, digits))
        }
    }
}

struct TrHealthRow: Identifiable {
    var def: TrHealthDef
    var points: [TrendsCalc.Point]
    var pairPoints: [TrendsCalc.Point]
    var main: String
    var unit: String
    var sub: String
    var spark: [TrendsCalc.Point]
    var id: String { def.id }
}

struct TrHealthGroup: Identifiable {
    var title: String
    var rows: [TrHealthRow]
    var id: String { title }
}

struct TrBodyModel {
    var readiness: [Readiness.Day]
    var off: TrendsCalc.OffTrends?
    var heart: [TrendsCalc.HeartPanel]
    var health: [TrHealthGroup]
    var measurements: [TrendsCalc.MeasureSeries]
    var now: Date

    init(_ d: Dashboard, now: Date) {
        self.now = now
        readiness = Readiness.history(d, now: now)
        off = TrendsCalc.offNormalTrends(d, now: now)
        heart = TrendsCalc.heart(d, now: now)
        measurements = TrendsCalc.measurements(d)
        let t30 = now.addingTimeInterval(-30 * 86400)
        var groups: [TrHealthGroup] = []
        for (title, defs) in TrHealthDef.groups {
            var rows: [TrHealthRow] = []
            for def in defs {
                let pts = TrendsCalc.metricPoints(d, def.id)
                guard let last = pts.last else { continue }
                let pair = def.pair.map { TrendsCalc.metricPoints(d, $0) } ?? []
                let lastPair = pair.first { $0.key == last.key }?.value
                let month = pts.filter { $0.at >= t30 }
                let monthPair = pair.filter { $0.at >= t30 }
                let avg: Double? = month.count > 1 ? Analytics.mean(month.map(\.value)) : nil
                let avgPair: Double? = monthPair.count > 1 ? Analytics.mean(monthPair.map(\.value)) : nil
                let (main, unit) = def.parts(last.value, lastPair)
                let sub = "\(TrendsCalc.short(last.key))\(avg.map { ". 30-day average \(def.text($0, avgPair))" } ?? "")"
                rows.append(TrHealthRow(def: def, points: pts, pairPoints: pair, main: main, unit: unit, sub: sub, spark: month))
            }
            if !rows.isEmpty { groups.append(TrHealthGroup(title: title, rows: rows)) }
        }
        health = groups
    }
}

// MARK: - Training

struct TrTrainingModel {
    var steps: (days: [TrendsCalc.Column], average: Double, count: Int)?
    var workouts: [Workout]
    var workoutCount: Int

    init(_ d: Dashboard, now: Date) {
        steps = TrendsCalc.steps(d, now: now)
        workouts = Array(d.workouts.prefix(8))
        workoutCount = (d.workoutCount ?? 0) > 0 ? d.workoutCount! : d.workouts.count
    }
}

// MARK: - More

struct TrMoreModel {
    var series: [String: [String: Double]]
    var earn: [TrendsCalc.EarnCell]
    var weekly: [[String]]
    var today: String

    init(_ d: Dashboard, now: Date) {
        var s: [String: [String: Double]] = [:]
        for m in TrendsCalc.catalog { s[m.id] = TrendsCalc.dailySeries(d, m.id) }
        series = s
        earn = TrendsCalc.earnDays(d, now: now)
        weekly = d.weeklySummary.reversed().prefix(8).map { w in
            [TrendsCalc.short(w.week), TrendsCalc.num(w.avgDailyCalories),
             w.avgProteinG.map { "\(TrendsCalc.num($0)) g" } ?? "—", w.avgWeightLb.map { TrendsCalc.num($0, 1) } ?? "—"]
        }
        today = LogTime.today(now)
    }
}
