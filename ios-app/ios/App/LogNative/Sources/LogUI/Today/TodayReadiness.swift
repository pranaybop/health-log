import SwiftUI
import LogCore

/// Today's readiness (Readiness in LogCore): a gauge with the 0–10 score, a small meter per
/// signal showing better or worse than your normal, and the last 7 days. The full breakdown and
/// history are on Trends › Body.
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

    /// One line on what moved the score most.
    var why: String {
        let core = day.parts.filter { $0.id != "load" }
        guard let top = core.max(by: { abs($0.z) < abs($1.z) }), abs(top.z) >= 0.5 else {
            return "HRV, resting heart rate and sleep are all close to your normal."
        }
        let what: String
        switch top.id {
        case "hrv": what = top.z > 0 ? "HRV is above your normal" : "HRV is below your normal"
        case "rhr": what = top.z > 0 ? "Resting heart rate is lower than usual" : "Resting heart rate is up"
        case "sleep": what = top.z > 0 ? "You slept more than usual" : "Sleep was short"
        default: what = ""
        }
        var s = what + "."
        if let n = day.daysSinceDose, n <= 2 { s += n == 0 ? " Shot day." : " Day \(n) after a shot." }
        return s
    }

    var body: some View {
        LogCard(isToday ? "Readiness" : "Readiness that day") {
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

/// HRV / Resting HR / Sleep with a centred meter: right and green is better than your normal,
/// left and amber is worse.
private struct SignalMeter: View {
    let part: Readiness.Part

    var value: String {
        switch part.id {
        case "sleep": return "\(Fmt.num(part.value, 1)) h"
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
