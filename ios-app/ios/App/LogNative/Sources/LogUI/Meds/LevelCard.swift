import SwiftUI
import Charts
import LogCore

struct MLLevelCard: View {
    let data: Dashboard
    @State private var selected: Date?

    var body: some View {
        if let lp = Analytics.levelPoints(data) {
            chartCard(lp)
        } else {
            LogCard("Drug level") { EmptyNote("No doses to chart yet.") }
        }
    }

    private func chartCard(_ lp: LevelPoints) -> some View {
        let now = Date()
        let levelNow = Analytics.remaining(at: now, doses: data.doses, protocols: data.protocols)
        let lastReal = data.doses.last { $0.skipped != true && $0.takenDate != nil }
        let lastT = lastReal?.takenDate ?? Date(timeIntervalSince1970: 0)
        let tail = lp.withNext.filter { $0.t >= lastT }
        let hasPlanned = zip(lp.withNext, lp.logged).contains { abs($0.v - $1.v) > 0.01 }
        let pick = selected.flatMap { nearest(lp.logged, $0) }
        let topV = max(lp.logged.map(\.v).max() ?? 1, lp.withNext.map(\.v).max() ?? 1)
        return LogCard("Drug level") {
            readout(lp, levelNow: levelNow, now: now, pick: pick)
            Chart {
                ForEach(lp.logged) { p in
                    AreaMark(x: .value("Time", p.t), yStart: .value("Base", 0.0), yEnd: .value("mg", p.v))
                        .foregroundStyle(LinearGradient(colors: [LogColor.s3.opacity(0.22), LogColor.s3.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                }
                ForEach(lp.logged) { p in
                    LineMark(x: .value("Time", p.t), y: .value("mg", p.v), series: .value("Series", "Logged doses"))
                        .foregroundStyle(LogColor.s3)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if hasPlanned {
                    ForEach(tail) { p in
                        LineMark(x: .value("Time", p.t), y: .value("mg", p.v), series: .value("Series", "With next planned shot"))
                            .foregroundStyle(LogColor.s3)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                    }
                }
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(LogColor.axis)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(LogColor.ink2)
                    }
                if let switchAt = LogTime.switchStart {
                    RuleMark(x: .value(LogTime.switchName, switchAt))
                        .foregroundStyle(LogColor.axis)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(LogTime.switchName).font(.caption2.weight(.semibold)).foregroundStyle(LogColor.ink2)
                        }
                }
                if let pick {
                    RuleMark(x: .value("Selected", pick.t))
                        .foregroundStyle(LogColor.ink2.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", pick.t), y: .value("mg", pick.v))
                        .foregroundStyle(LogColor.s3)
                        .symbolSize(40)
                }
            }
            .chartXScale(domain: lp.start...max(lp.end, lp.start.addingTimeInterval(86400)))
            .chartYScale(domain: 0...max(topV * 1.08, 0.5))
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(LogColor.grid)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Fmt.num(v, v < 10 ? 1 : 0)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(LogColor.grid)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .environment(\.timeZone, LogTime.zone)
            .frame(height: 210)
            .padding(.top, 6)
            .accessibilityLabel("Estimated drug level over time")
            .accessibilityValue("\(Fmt.num(levelNow, 2)) mg now")
            HStack(spacing: 16) {
                MLLegendLine(color: LogColor.s3, dashed: false, label: "Logged doses")
                if hasPlanned { MLLegendLine(color: LogColor.s3, dashed: true, label: "With next planned shot") }
            }
            Caption(caption)
        }
    }

    @ViewBuilder
    private func readout(_ lp: LevelPoints, levelNow: Double, now: Date, pick: LevelSample?) -> some View {
        if let p = pick {
            let planned = p.id < lp.withNext.count ? lp.withNext[p.id].v : p.v
            let extra = abs(planned - p.v) > 0.01 ? ", \(Fmt.num(planned, 2)) mg with next shot" : ""
            BigNumber(Fmt.num(p.v, 2), unit: "mg", detail: "\(MLFmt.day(p.t)), \(MLFmt.timeCT(p.t))\(extra)", size: 30)
        } else {
            BigNumber(Fmt.num(levelNow, 2), unit: "mg", detail: "Estimated now, \(MLFmt.timeCT(now))", size: 30)
        }
    }

    private func nearest(_ pts: [LevelSample], _ t: Date) -> LevelSample? {
        pts.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
    }

    private var caption: String {
        let tirz = Fmt.mg(Analytics.halfLifeDays("tirzepatide", protocols: data.protocols))
        let reta = Fmt.mg(Analytics.halfLifeDays("retatrutide", protocols: data.protocols))
        let dashed = LogTime.switchStart.map {
            " The dashed line adds the next planned tirzepatide shot if it falls before the \(LogTime.switchName) switch on \(LogTime.shortDate($0))."
        } ?? ""
        return "Half-life model: tirzepatide \(tirz) days, retatrutide \(reta) days.\(dashed) No retatrutide mg amount is assumed. An estimate, not a lab value."
    }
}
