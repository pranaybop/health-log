import SwiftUI
import LogCore

/// Readiness for the last 60 days, worked out once per payload rather than on every redraw
/// (Today rebuilds its model whenever it renders, and swiping days asks for other keys).
@MainActor
enum ReadinessCache {
    private static var stamp = ""
    private static var byKey: [String: Readiness.Day] = [:]

    private static func fill(_ d: Dashboard) {
        let today = LogTime.today()
        let points = d.healthMetrics.reduce(0) { $0 + $1.value.count }
        let s = "\(d.asOf ?? "")|\(d.dailyHealth.count)|\(d.workouts.count)|\(d.weights.count)|\(d.doses.count)|\(points)|\(today)"
        guard s != stamp else { return }
        stamp = s
        byKey = [:]
        for day in Readiness.history(d, now: LogTime.noon(today), days: 90) { byKey[day.key] = day }
    }

    static func day(_ key: String, in d: Dashboard) -> Readiness.Day? {
        fill(d)
        return byKey[key]
    }

    /// The 7 days ending on `key` that have a score.
    static func week(ending key: String, in d: Dashboard) -> [Readiness.Day] {
        fill(d)
        return (0..<7).reversed().compactMap { byKey[LogTime.shift(key, -$0)] }
    }
}

/// Today's readiness (Readiness in LogCore): a gauge with the 0–10 score, a small meter per
/// scored signal (except training load) showing better or worse than your normal, one line
/// naming the one or two signals that moved it most, and the last 7 days. The full breakdown
/// and history are on Trends › Body.
struct TodayReadiness: View {
    let day: Readiness.Day
    let week: [Readiness.Day]
    let isToday: Bool

    static func tone(_ score: Double) -> Color {
        score >= 7 ? LogColor.good : score >= 4 ? LogColor.s1 : LogColor.warn
    }

    var headline: String {
        switch day.score {
        case 7...: return "Ready to push"
        case 5.5..<7: return "A normal day for you"
        case 4..<5.5: return "A bit below your normal"
        default: return "Take it easier today"
        }
    }

    /// What moved the score: the one or two largest contributors (Readiness.whatMoved).
    var why: String { Readiness.whatMoved(day) }

    var body: some View {
        Button { TrendsRouter.open("body", card: "readiness") } label: { card }
            .buttonStyle(.plain)
            .accessibilityHint("Opens readiness on Trends")
    }

    private var card: some View {
        LogCard(isToday ? "Readiness" : "Readiness that day", accessory: {
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LogColor.ink2)
        }) {
            HStack(alignment: .center, spacing: 18) {
                ReadinessGauge(score: day.score, color: Self.tone(day.score))
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(LogColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(day.parts.filter { $0.id != "load" }) { p in
                        SignalMeter(part: p)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(why)
                .font(.subheadline)
                .foregroundStyle(LogColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if week.count >= 2 { WeekStrip(days: week, selected: day.key) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Readiness \(Fmt.num(day.score, 1)) out of 10. \(headline). \(why)")
    }
}

/// A three-quarter arc, filled to the score, with the number in the middle.
private struct ReadinessGauge: View {
    let score: Double
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 116
    @State private var shown: Double = 0

    var body: some View {
        let side = min(size, 140)
        let width = side * 0.1
        ZStack {
            arc(1).stroke(LogColor.surface2, style: StrokeStyle(lineWidth: width, lineCap: .round))
            arc(max(0.001, shown / 10))
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                        startAngle: .degrees(135), endAngle: .degrees(135 + 270 * max(0.01, shown / 10))),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
            VStack(spacing: 0) {
                Text(Fmt.num(score, 1))
                    .font(.logNumber(side * 0.3))
                    .foregroundStyle(LogColor.ink)
                    .contentTransition(.numericText())
                Text("of 10").font(.caption.weight(.semibold)).foregroundStyle(LogColor.ink2)
            }
            .offset(y: side * 0.03)
        }
        .frame(width: side, height: side)
        .onAppear { withAnimation(.easeOut(duration: 0.8)) { shown = score } }
        .onChange(of: score) { _, v in withAnimation(.easeOut(duration: 0.5)) { shown = v } }
        .accessibilityHidden(true)
    }

    /// The arc from 7:30 round to 4:30, `fraction` of the way.
    private func arc(_ fraction: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: 0.75 * min(1, fraction))
            .rotation(.degrees(135))
    }
}

/// One scored signal with a centred meter: right and green is better than your normal,
/// left and amber is worse. Training load stays on the Trends breakdown.
private struct SignalMeter: View {
    let part: Readiness.Part

    var value: String {
        switch part.id {
        case "sleep": return "\(Fmt.num(part.value, 1)) h"
        case "stages": return "\(Fmt.num(part.value, 0)) min"
        case "temp": return "\(Fmt.num(part.value, 2)) °F"
        case "resp": return "\(Fmt.num(part.value, 1))/min"
        case "spo2": return "\(Fmt.num(part.value, 1))%"
        default: return "\(Fmt.num(part.value, 0)) \(part.unit)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(part.label).font(.caption.weight(.semibold)).foregroundStyle(LogColor.ink2)
                Spacer(minLength: 4)
                Text(value).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(LogColor.ink)
            }
            GeometryReader { g in
                let half = g.size.width / 2
                let len = half * CGFloat(min(1, abs(part.z) / 3))
                ZStack(alignment: .leading) {
                    Capsule().fill(LogColor.surface2)
                    Capsule()
                        .fill(part.z >= 0 ? LogColor.good : LogColor.warn)
                        .frame(width: max(4, len))
                        .offset(x: part.z >= 0 ? half : half - max(4, len))
                    Rectangle().fill(LogColor.ink2.opacity(0.5)).frame(width: 1.5).offset(x: half - 0.75)
                }
            }
            .frame(height: 6)
        }
    }
}

/// The last 7 days as small columns, today's outlined.
private struct WeekStrip: View {
    let days: [Readiness.Day]
    let selected: String

    /// "M", "T", … for a day key (worked out in UTC, where the key's noon instant sits on that date).
    static func letter(_ key: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let w = cal.component(.weekday, from: LogTime.noon(key)) // 1 = Sunday
        return ["S", "M", "T", "W", "T", "F", "S"][(w - 1) % 7]
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { d in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(TodayReadiness.tone(d.score).opacity(d.key == selected ? 1 : 0.45))
                        .frame(height: max(4, 34 * d.score / 10))
                    Text(Self.letter(d.key))
                        .font(.caption2.weight(d.key == selected ? .bold : .regular))
                        .foregroundStyle(d.key == selected ? LogColor.ink : LogColor.ink2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 52, alignment: .bottom)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}
