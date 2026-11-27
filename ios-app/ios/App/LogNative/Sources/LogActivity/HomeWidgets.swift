import Foundation
import SwiftUI
import WidgetKit
import LogCore

// Home Screen and Lock Screen widgets: weight trend and progress, today's readiness, and
// calories and protein today. The app writes a small snapshot to the shared app group after
// every refresh (HomeWidgets.publish); the LogWidgets extension only reads it. Tapping a widget
// opens the app on the matching screen (pranaybop-log://…, handled by DeepLink in LogUI).

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var asOf: Date
    public var trend: Double?
    public var lastWeighIn: Double?
    public var lost: Double?
    public var goal: Double?
    public var fraction: Double?
    public var toGo: Double?
    public var weekly: Double?
    public var goalETA: Date?
    /// Trend, one point a day for the last 30 days.
    public var spark: [Double]
    public var readiness: Double?
    public var readinessBand: String?
    public var calories: Double?
    public var calorieTarget: Double?
    public var protein: Double?
    public var proteinTarget: Double?

    public static let appGroup = "group.com.pranaybop.log"
    static let key = "log.widgetSnapshot"

    public static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }

    public static func make(_ d: Dashboard, now: Date = Date()) -> WidgetSnapshot {
        let sm = Analytics.smoothWeights(d)
        let since = Analytics.Trends.firstGlp1At(d)
        let p = WeightProgress.make(sm, startLb: d.profile?.startWeightLb, goalLb: d.profile?.goalWeightLb, since: since, now: now)
        let today = LogTime.today(now)
        var spark: [Double] = []
        for i in (0..<30).reversed() {
            let t = LogTime.noon(LogTime.shift(today, -i)).addingTimeInterval(6 * 3600)
            if let v = Analytics.trend(at: t, in: sm) { spark.append(v) }
        }
        let r = Readiness.day(today, d: d, trend: sm) ?? Readiness.day(LogTime.shift(today, -1), d: d, trend: sm)
        let food = d.dailyTotals.first { $0.date == today }
        let t = Analytics.Trends.targets(d)
        return WidgetSnapshot(asOf: now, trend: sm.last?.trend, lastWeighIn: sm.last?.lb, lost: p?.done, goal: p?.goal,
                              fraction: p?.fraction, toGo: p?.toGo, weekly: p?.weekly, goalETA: p?.goalETA, spark: spark,
                              readiness: r?.score, readinessBand: r?.band, calories: food?.calories ?? 0, calorieTarget: t.calories,
                              protein: food?.proteinG ?? 0, proteinTarget: t.protein)
    }

    /// Calories and protein belong to the day they were counted on.
    public func isToday(_ now: Date = Date()) -> Bool { LogTime.dayKey(asOf) == LogTime.dayKey(now) }
}

public enum HomeWidgets {
    /// Called by the app whenever the data changes. Only reloads the widgets when what they
    /// show changed.
    @MainActor
    public static func publish(_ d: Dashboard, now: Date = Date()) {
        var snap = WidgetSnapshot.make(d, now: now)
        if let old = WidgetSnapshot.load(), LogTime.dayKey(old.asOf) == LogTime.dayKey(now) {
            var same = old
            same.asOf = snap.asOf
            if same == snap { return }
        }
        snap.asOf = now
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Timeline

public struct SnapshotEntry: TimelineEntry {
    public let date: Date
    public let snap: WidgetSnapshot?
}

public struct SnapshotProvider: TimelineProvider {
    public init() {}

    static let sample = WidgetSnapshot(asOf: Date(), trend: 258.4, lastWeighIn: 257.9, lost: 13.4, goal: 235, fraction: 0.36,
                                       toGo: 23.4, weekly: -1.4, goalETA: Date().addingTimeInterval(110 * 86400),
                                       spark: (0..<30).map { 266 - Double($0) * 0.26 + sin(Double($0)) * 0.3 },
                                       readiness: 6.4, readinessBand: "Normal", calories: 1240, calorieTarget: 2200,
                                       protein: 96, proteinTarget: 150)

    public func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snap: Self.sample) }

    public func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snap: context.isPreview ? (WidgetSnapshot.load() ?? Self.sample) : WidgetSnapshot.load()))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snap: WidgetSnapshot.load())
        // The app reloads the widgets when data changes; also redraw just after midnight so
        // calories and protein reset to the new day.
        let midnight = LogTime.startOfDay(LogTime.shift(LogTime.today(), 1)).addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

// MARK: - Look

enum WColor {
    static let teal = Color(red: 0.07, green: 0.60, blue: 0.50)
    static let orange = Color(red: 0.84, green: 0.42, blue: 0.12)
    static let amber = Color(red: 0.96, green: 0.70, blue: 0.08)
    static let green = Color(red: 0.04, green: 0.67, blue: 0.14)

    static func readiness(_ s: Double) -> Color { s >= 7 ? green : s >= 4 ? teal : amber }
}

func wnum(_ v: Double?, _ digits: Int = 0) -> String {
    guard let v, v.isFinite else { return "—" }
    return String(format: "%.\(digits)f", v)
}

func wsigned(_ v: Double?, _ digits: Int = 1) -> String {
    guard let v, v.isFinite else { return "—" }
    let s = String(format: "%.\(digits)f", abs(v))
    return v > 0 ? "+" + s : v < 0 ? "−" + s : s
}

struct EmptyWidget: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Log").font(.headline)
            Text("Open the app to load your data.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { g in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let span = max(0.5, hi - lo)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = g.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = g.size.height * CGFloat(1 - (v - lo) / span)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Weight

struct WeightWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: SnapshotEntry

    var body: some View {
        Group {
            if let s = entry.snap, s.trend != nil { content(s) } else { EmptyWidget() }
        }
        .widgetURL(URL(string: "pranaybop-log://trends/weight"))
    }

    @ViewBuilder
    func content(_ s: WidgetSnapshot) -> some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: s.fraction ?? 0) {
                Text("lb")
            } currentValueLabel: {
                Text(wnum(s.trend)).font(.system(.body, design: .rounded).weight(.bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(wnum(s.trend, 1)) lb").font(.headline)
                Text("\(wsigned(s.lost.map { -$0 })) lb since start").font(.caption)
                if let f = s.fraction, let g = s.goal { Text("\(Int((f * 100).rounded()))% to \(wnum(g))").font(.caption) }
            }
        case .accessoryInline:
            Text("\(wnum(s.trend, 1)) lb · \(wsigned(s.weekly, 1))/wk")
        case .systemMedium:
            HStack(spacing: 14) {
                summary(s)
                VStack(alignment: .leading, spacing: 6) {
                    Sparkline(values: s.spark, color: WColor.teal).frame(height: 50)
                    Text(s.weekly.map { "\(wsigned($0, 2)) lb a week" } ?? "Pace building")
                        .font(.caption.weight(.semibold))
                    if let eta = s.goalETA {
                        Text("Goal around \(eta.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        default:
            summary(s)
        }
    }

    func summary(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Weight trend").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(wnum(s.trend, 1)).font(.system(size: 30, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                Text("lb").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text("\(wsigned(s.lost.map { -$0 })) lb since start").font(.caption.weight(.semibold)).foregroundStyle(WColor.teal)
            Spacer(minLength: 0)
            if let f = s.fraction, let g = s.goal {
                ProgressView(value: f).tint(WColor.teal)
                Text("\(Int((f * 100).rounded()))% to \(wnum(g))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

public struct WeightWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LogWeight", provider: SnapshotProvider()) { entry in
            WeightWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Weight trend")
        .description("Your smoothed weight, how far you've come and how far to go.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Readiness

struct ReadinessWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: SnapshotEntry

    var body: some View {
        Group {
            if let s = entry.snap, let score = s.readiness { content(s, score) } else { EmptyWidget() }
        }
        .widgetURL(URL(string: "pranaybop-log://trends/body"))
    }

    @ViewBuilder
    func content(_ s: WidgetSnapshot, _ score: Double) -> some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: score, in: 0...10) {
                Text("Ready")
            } currentValueLabel: {
                Text(wnum(score, 1))
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Readiness \(wnum(score, 1))").font(.headline)
                Text(s.readinessBand ?? "").font(.caption)
            }
        case .accessoryInline:
            Text("Readiness \(wnum(score, 1)) · \(s.readinessBand ?? "")")
        default:
            VStack(spacing: 6) {
                Text("Readiness").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Gauge(value: score, in: 0...10) {
                    EmptyView()
                } currentValueLabel: {
                    Text(wnum(score, 1)).font(.system(.title, design: .rounded).weight(.bold))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(WColor.readiness(score))
                .scaleEffect(1.35)
                .frame(height: 64)
                Text(s.readinessBand ?? "").font(.caption.weight(.semibold)).foregroundStyle(WColor.readiness(score))
            }
        }
    }
}

public struct ReadinessWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LogReadiness", provider: SnapshotProvider()) { entry in
            ReadinessWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Readiness")
        .description("Today's 0–10 score from HRV, resting heart rate, sleep and training.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Food

struct FoodWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: SnapshotEntry

    var body: some View {
        Group {
            if let s = entry.snap { content(s) } else { EmptyWidget() }
        }
        .widgetURL(URL(string: "pranaybop-log://today"))
    }

    func left(_ s: WidgetSnapshot) -> Double? {
        guard let t = s.calorieTarget else { return nil }
        return t - (s.isToday(entry.date) ? (s.calories ?? 0) : 0)
    }

    @ViewBuilder
    func content(_ s: WidgetSnapshot) -> some View {
        let kcal = s.isToday(entry.date) ? (s.calories ?? 0) : 0
        let protein = s.isToday(entry.date) ? (s.protein ?? 0) : 0
        switch family {
        case .accessoryCircular:
            Gauge(value: min(1, kcal / max(1, s.calorieTarget ?? 2000))) {
                Text("kcal")
            } currentValueLabel: {
                Text(wnum(left(s)))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(wnum(left(s))) kcal left").font(.headline)
                Text("\(wnum(protein)) / \(wnum(s.proteinTarget)) g protein").font(.caption)
            }
        case .accessoryInline:
            Text("\(wnum(left(s))) kcal left · \(wnum(protein)) g protein")
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("Food today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(wnum(left(s))).font(.system(size: 30, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                    Text("kcal left").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, kcal / max(1, s.calorieTarget ?? 2000))).tint(WColor.teal)
                Spacer(minLength: 0)
                Text("Protein \(wnum(protein)) / \(wnum(s.proteinTarget)) g").font(.caption.weight(.semibold))
                ProgressView(value: min(1, protein / max(1, s.proteinTarget ?? 150))).tint(WColor.orange)
            }
        }
    }
}

public struct FoodWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LogFood", provider: SnapshotProvider()) { entry in
            FoodWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Food today")
        .description("Calories left and protein against your targets.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
