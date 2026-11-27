import SwiftUI
import LogCore

// Body section: off your normal (renderOffNormalTrends), heart (renderHeartCard), more from
// Apple Health (renderMoreHealth) and measurements (renderMeasurements).

struct TrBodySectionView: View {
    var m: TrBodyModel
    var canSync: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            if let latest = m.readiness.last { TrReadinessCard(latest: latest, days: m.readiness).id("readiness") }
            if let off = m.off { TrOffNormalCard(o: off, now: m.now).id("off-normal") }
            if !m.heart.isEmpty { TrHeartCard(panels: m.heart, now: m.now).id("heart") }
            if !m.health.isEmpty || canSync { TrMoreHealthCard(groups: m.health, now: m.now).id("more-health") }
            TrMeasurementsCard(series: m.measurements, now: m.now).id("measurements")
        }
    }
}

// MARK: - Readiness

struct TrReadinessCard: View {
    var latest: Readiness.Day
    var days: [Readiness.Day]

    func tone(_ score: Double) -> Color {
        score >= 7 ? LogColor.good : score >= 4 ? LogColor.s1 : LogColor.warn
    }

    func partValue(_ p: Readiness.Part) -> String {
        switch p.id {
        case "sleep": return "\(TrendsCalc.num(p.value, 1)) h"
        case "load": return p.value < 1 ? "Rest" : TrendsCalc.num(p.value)
        default: return "\(TrendsCalc.num(p.value)) \(p.unit)"
        }
    }

    func partNormal(_ p: Readiness.Part) -> String {
        switch p.id {
        case "sleep": return "normal \(TrendsCalc.num(p.normal, 1)) h"
        case "load": return "normal \(TrendsCalc.num(p.normal))"
        default: return "normal \(TrendsCalc.num(p.normal)) \(p.unit)"
        }
    }

    func context(_ day: Readiness.Day) -> String {
        var bits: [String] = []
        if let n = day.daysSinceDose { bits.append(n == 0 ? "Shot day" : "Day \(n) after a shot") }
        if let k = day.calories { bits.append("\(TrendsCalc.num(k)) kcal logged") }
        if let w = day.weightTrend { bits.append("weight trend \(TrendsCalc.num(w, 1)) lb") }
        return bits.joined(separator: " · ")
    }

    var body: some View {
        LogCard("Readiness") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TrendsCalc.num(latest.score, 1)).font(.logNumber(40)).foregroundStyle(tone(latest.score))
                Text("/ 10").font(.headline).foregroundStyle(LogColor.ink2)
                Spacer()
                TrBadge(latest.band, tone: latest.score < 4 ? .watch : .quiet)
            }
            Text(latest.key == LogTime.today() ? "Today" : TrendsCalc.short(latest.key))
                .font(.subheadline).foregroundStyle(LogColor.ink2)
            let ctx = context(latest)
            if !ctx.isEmpty { Caption(ctx) }
            VStack(spacing: 0) {
                ForEach(Array(latest.parts.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Divider().overlay(LogColor.hairline) }
                    HStack(spacing: 10) {
                        Text(p.label).font(.subheadline).foregroundStyle(LogColor.ink)
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(partValue(p)).font(.logNumber(15)).foregroundStyle(LogColor.ink)
                            Text(partNormal(p)).font(.caption2).foregroundStyle(LogColor.ink2)
                        }
                        TrBadge(abs(p.z) < 0.5 ? "Normal" : (p.z > 0 ? "Better" : "Worse"), tone: p.z <= -1 ? .watch : .quiet)
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
            if days.count >= 3 {
                TrColumnChart(columns: days.map { TrendsCalc.Column(key: $0.key, value: $0.score) }, color: LogColor.s4,
                              height: 120, main: "\(TrendsCalc.num(days.map(\.score).reduce(0, +) / Double(days.count), 1)) average",
                              sub: "Last \(days.count) scored days",
                              scrub: { c in
                                  let day = days.first { $0.key == c.key }
                                  return ("\(TrendsCalc.num(c.value, 1)) / 10", [TrendsCalc.short(c.key), day.map(context) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                              },
                              aria: "Readiness, last 30 days")
            }
            TrDisclosure(title: "Next to food, weight and shots", headers: ["Day", "Score", "kcal", "Trend", "Shot"], rows: days.reversed().map { day in
                [TrendsCalc.short(day.key), TrendsCalc.num(day.score, 1), TrendsCalc.num(day.calories),
                 TrendsCalc.num(day.weightTrend, 1), day.daysSinceDose.map { $0 == 0 ? "Shot" : "+\($0)d" } ?? ""]
            })
            Caption("Overnight HRV (35%), resting heart rate (30%), sleep (25%) and the last 3 days’ training against the 4 weeks before (10%), each compared with your own last 4 weeks. 5 is a normal day for you. It tracks the same signals as watch readiness scores but won’t match them, and it isn’t medical advice.")
        }
    }
}

struct TrSignalRows: View {
    var r: TrendsCalc.OffNormal

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<r.checked.count, id: \.self) { i in
                if i > 0 { Divider().overlay(LogColor.hairline) }
                row(r.checked[i])
            }
        }
    }

    func row(_ c: TrendsCalc.SignalCheck) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(c.def.label).font(.subheadline).foregroundStyle(LogColor.ink)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(c.text(c.value)).font(.logNumber(15)).foregroundStyle(LogColor.ink)
                Text("normal \(c.text(c.median))").font(.caption2).foregroundStyle(LogColor.ink2)
            }
            TrBadge(c.off ? "\(c.def.up ? "▲" : "▼") \(c.diffText)" : "Normal", tone: c.off ? .watch : .quiet)
                .frame(minWidth: 78, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct TrOffNormalCard: View {
    var o: TrendsCalc.OffTrends
    var now: Date

    static let causes = "Common causes: a hard workout, short or late sleep, alcohol, a dose change, or getting sick."

    func color(_ d: TrendsCalc.OffDay) -> Color {
        if d.flagged { return LogColor.warnInk }
        if d.checked >= 2 { return LogColor.s1.opacity(0.3) }
        return LogColor.surface2
    }

    var body: some View {
        let flagged = o.flagged
        return LogCard("Off your normal") {
            if let latest = o.latest {
                let off = latest.off.count
                let n = latest.checked.count
                let state = off > 0 ? "\(off) of \(n) signals off" : "all \(n) signals normal"
                TrLead("\(TrendsCalc.dayTitle(latest.key, now: now)): \(state)")
                TrSignalRows(r: latest)
            }
            TrSubHead("Last 60 days")
            VStack(spacing: 4) {
                HStack(spacing: 1) {
                    ForEach(o.days) { d in
                        RoundedRectangle(cornerRadius: 2).fill(LogColor.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 2).fill(color(d)))
                            .frame(height: 22)
                    }
                }
                HStack {
                    Text(TrendsCalc.short(o.days.first?.key))
                    Spacer()
                    Text("Today")
                }
                .font(.caption2)
                .foregroundStyle(LogColor.ink2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(flagged.isEmpty ? "No off-normal days in the last 60" : "Off-normal days in the last 60: \(flagged.map { TrendsCalc.short($0.key) }.joined(separator: ", "))")
            TrLegend(items: [
                TrLegendItem(key: .rect(LogColor.warnInk), label: "Two or more off"),
                TrLegendItem(key: .rect(LogColor.s1.opacity(0.3)), label: "Normal"),
                TrLegendItem(key: .outlined(LogColor.surface2, LogColor.hairline), label: "Not enough data"),
            ])
            Caption(flagged.isEmpty
                    ? "No days with two or more signals off (\(o.tracked) days had enough data)."
                    : "\(flagged.count) day\(TrendsCalc.s(flagged.count)) with two or more signals off.")
            if !flagged.isEmpty {
                TrProps(rows: flagged.suffix(5).reversed().map { d in
                    (TrendsCalc.short(d.key), d.off.map { "\($0.def.lower) \($0.diffText)" }.joined(separator: ", "))
                })
            }
            Caption("Each signal is compared with the middle of its previous 30 days. Off means past twice its usual spread, and at least 4 bpm resting heart rate, 20% HRV, 1.5 breaths a minute or 0.9 °F wrist temperature. Today shows a card when two or more are off. \(Self.causes)")
        }
    }
}

struct TrHeartCard: View {
    var panels: [TrendsCalc.HeartPanel]
    var now: Date

    var body: some View {
        LogCard("Heart") {
            ForEach(0..<panels.count, id: \.self) { i in
                panel(panels[i], color: panels[i].higherIsBetter ? LogColor.s4 : LogColor.s3)
            }
            Caption("From Apple Health. The badge compares the last 7 days with the 30 days before tirzepatide.\(LogTime.switchStart.map { " Watch resting heart rate after the \(LogTime.switchName) switch on \(LogTime.shortDate($0)): the retatrutide trials reported it rising." } ?? "")")
        }
    }

    func panel(_ p: TrendsCalc.HeartPanel, color: Color) -> some View {
        let unit = p.unit
        var marks = [TrMark(at: LogTime.tirzStart, label: LogTime.journeyName)]
        if let switchAt = LogTime.switchStart, switchAt <= now { marks.append(TrMark(at: switchAt, label: LogTime.switchName)) }
        let readout: TrScrub = p.recent.map { r in
            ("\(TrendsCalc.num(r)) \(unit)", "7-day average\(p.base.map { ". Before \(LogTime.journeyName.lowercased()): \(TrendsCalc.num($0))" } ?? "")")
        } ?? ("—", "")
        var tone = TrTone.steady
        if let delta = p.delta, abs(delta) >= 2 { tone = (delta > 0) == p.higherIsBetter ? .good : .watch }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TrSubHead(p.title, key: .line(color))
                if let delta = p.delta { TrBadge("\(TrendsCalc.signed(delta, 0)) \(unit)", tone: tone) }
            }
            TrTimeChart(t0: now.addingTimeInterval(-120 * 86400), t1: now,
                        series: [
                            TrSeries(id: "d", kind: .dots, color: color, points: p.points, faint: true, radius: 2),
                            TrSeries(id: "s", kind: .smooth, color: color, points: p.smooth, endDot: true),
                        ],
                        marks: marks, height: 150, snap: "s", readout: readout,
                        scrub: { pt, readings in
                            let day = readings["d"].flatMap { $0.key == pt.key ? $0 : nil }
                            return ("\(TrendsCalc.num(pt.value)) \(unit)",
                                    "\(LogTime.weekdayDate(pt.at)), 7-day average\(day.map { ". That day \(TrendsCalc.num($0.value))" } ?? "")")
                        },
                        aria: "\(p.title), last 120 days")
        }
    }
}

struct TrMoreHealthCard: View {
    var groups: [TrHealthGroup]
    var now: Date
    @State var open: Set<String> = []

    var body: some View {
        LogCard("More from Apple Health") {
            if groups.isEmpty {
                Caption("Nothing here yet. Heart rate, breathing, blood oxygen, sleep stages, energy and the rest show up after the next sync.")
            } else {
                ForEach(groups) { g in
                    TrSubHead(g.title)
                    VStack(spacing: 0) {
                        ForEach(0..<g.rows.count, id: \.self) { i in
                            if i > 0 { Divider().overlay(LogColor.hairline) }
                            row(g.rows[i])
                        }
                    }
                }
                Caption("Synced from Apple Health by the Log iPhone app. Tap a row for the last 120 days.")
            }
        }
    }

    func row(_ r: TrHealthRow) -> some View {
        let isOpen = open.contains(r.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { open.remove(r.id) } else { open.insert(r.id) }
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.def.label).font(.subheadline).foregroundStyle(LogColor.ink).multilineTextAlignment(.leading)
                        Text(r.sub).font(.caption).foregroundStyle(LogColor.ink2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 6)
                    TrSparkline(points: r.spark, from: now.addingTimeInterval(-30 * 86400), to: now, width: 56, height: 22)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(r.main).font(.logNumber(16)).foregroundStyle(LogColor.ink)
                        if !r.unit.isEmpty {
                            Text(["%", "°F", "/min"].contains(r.unit) ? r.unit : " " + r.unit).font(.caption2.weight(.semibold)).foregroundStyle(LogColor.ink2)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LogColor.ink2)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the chart" : "Shows the last 120 days")
            if isOpen { chart(r).padding(.bottom, 10) }
        }
    }

    func chart(_ r: TrHealthRow) -> some View {
        let def = r.def
        var pairMap: [String: Double] = [:]
        for p in r.pairPoints { pairMap[p.key] = p.value }
        var series = [
            TrSeries(id: "d", kind: .dots, color: LogColor.s1, points: r.points, faint: true, radius: 2),
            TrSeries(id: "s", kind: .smooth, color: LogColor.s1, points: TrendsCalc.rolling(r.points, days: 7), endDot: true),
        ]
        if !r.pairPoints.isEmpty {
            series.append(TrSeries(id: "d2", kind: .dots, color: LogColor.s2, points: r.pairPoints, faint: true, radius: 2))
            series.append(TrSeries(id: "s2", kind: .smooth, color: LogColor.s2, points: TrendsCalc.rolling(r.pairPoints, days: 7), endDot: true))
        }
        let last = r.points[r.points.count - 1]
        let readout: TrScrub = (def.text(last.value, pairMap[last.key]), "\(TrendsCalc.short(last.key)). The line is a 7-day average.")
        let pairs = pairMap
        return VStack(alignment: .leading, spacing: 6) {
            TrTimeChart(t0: now.addingTimeInterval(-120 * 86400), t1: now, series: series, height: 140,
                        fmtY: { def.axis($0) }, snap: "d", readout: readout,
                        scrub: { p, _ in (def.text(p.value, pairs[p.key]), LogTime.weekdayDate(p.at)) },
                        aria: "\(def.label), last 120 days")
            if !r.pairPoints.isEmpty {
                TrLegend(items: [TrLegendItem(key: .line(LogColor.s1), label: "Systolic"), TrLegendItem(key: .line(LogColor.s2), label: "Diastolic")])
            }
        }
    }
}

struct TrMeasurementsCard: View {
    var series: [TrendsCalc.MeasureSeries]
    var now: Date

    var body: some View {
        LogCard("Measurements") {
            if series.isEmpty {
                EmptyNote("No tape measurements yet. Log waist or other metrics on the Log tab.")
            } else {
                ForEach(series) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        TrSubHead(TrendsCalc.capitalize(s.name))
                        sub(s)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func sub(_ s: TrendsCalc.MeasureSeries) -> some View {
        let unit = s.unit
        if let first = s.points.first, let last = s.points.last {
            let readout: TrScrub = ("\(TrendsCalc.num(last.value, 1)) \(unit)", "Latest, \(LogTime.weekdayDate(last.at))")
            if s.points.count >= 2 {
                TrTimeChart(t0: first.at, t1: max(now, last.at),
                            series: [
                                TrSeries(id: "m", kind: .line, color: LogColor.s1, points: s.points, endDot: true),
                                TrSeries(id: "md", kind: .dots, color: LogColor.s1, points: s.points),
                            ],
                            height: 150, fmtY: { TrendsCalc.num($0, 1) }, snap: "m", readout: readout,
                            scrub: { p, _ in ("\(TrendsCalc.num(p.value, 1)) \(unit)", LogTime.weekdayDate(p.at)) },
                            aria: s.name)
            } else {
                TrReadout(main: readout.main, sub: readout.sub)
                EmptyNote("Log one more to see a trend.")
            }
        } else {
            TrReadout(main: "—", sub: "")
            EmptyNote("Log one more to see a trend.")
        }
    }
}
