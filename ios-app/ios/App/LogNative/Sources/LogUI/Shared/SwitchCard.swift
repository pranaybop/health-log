import SwiftUI
import Charts
import LogCore

/// The tirzepatide → retatrutide switch card. Meds shows it in
/// its list; Today shows it on today's page.
///
/// Draws nothing once the first retatrutide dose is more than
/// two weeks old (or before the data has loaded).
public struct SwitchCard: View {
    @Environment(LogStore.self) private var store

    public init() {}

    /// Whether the card shows for this data.
    static func shows(_ d: Dashboard, now: Date = Date()) -> Bool {
        guard LogTime.hasSwitch else { return false }
        guard let first = Analytics.firstRetaDose(d), let t = first.takenDate else { return true }
        return LogTime.daysUntil(t, now: now) >= -14
    }

    public var body: some View {
        if let d = store.dashboard, Self.shows(d) {
            content(d)
        }
    }

    private func content(_ d: Dashboard) -> some View {
        let start = Analytics.retaSwitchAt(d)
        let days = LogTime.daysUntil(start)
        let first = Analytics.firstRetaDose(d)
        let rot = Analytics.siteRotation(d)
        let next = MLFmt.site(rot.next)
        let p = Analytics.protocolRow(d, "retatrutide")
        let units = p?.units
        let mg = p?.typicalDoseMg
        let doseText: String
        if let u = units {
            let extra = mg.map { " (\(Fmt.num($0, 1)) mg at \(Fmt.num($0 / (u / 100), 0)) mg/mL)" } ?? ""
            doseText = "Take \(Fmt.num(u, 0)) units\(extra)."
        } else if let m = mg {
            doseText = "Take \(Fmt.num(m, 1)) mg."
        } else {
            doseText = "Take the planned first dose."
        }
        let headline: String
        if let t = first?.takenDate { headline = "First retatrutide dose logged \(MLFmt.day(t))." }
        else if days > 0 { headline = "Switch in \(MLFmt.count(days, "day")), \(MLFmt.day(start))." }
        else if days == 0 { headline = "Switch day is today." }
        else { headline = "Planned start was \(MLFmt.day(start)). No retatrutide dose is logged yet." }
        let items = [
            "Mix the vial with 1 mL.",
            doseText,
            "Don’t overlap with tirzepatide — this is a switch, not a stack.",
            "Next site: \(next).",
        ]
        return LogCard("Retatrutide switch") {
            Text(headline).font(.headline).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                    if i > 0 { MLHairline() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(LogColor.axis, lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                            .accessibilityHidden(true)
                        Text(text).font(.subheadline).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 9)
                }
            }
            Text("Half-life shape").font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink)
            MLHalfLifeChart()
            HStack(spacing: 16) {
                MLLegendLine(color: LogColor.s3, dashed: true, label: "Tirzepatide, 5 days")
                MLLegendLine(color: LogColor.s2, dashed: false, label: "Retatrutide, 6 days")
            }
            Caption("The chart is the share left after a dose, not milligrams, so it compares the 144-hour and 120-hour half-lives on the same scale.")
        }
    }
}

/// The share left after one dose over 14 days, at 5- and 6-day half-lives.
struct MLHalfLifeChart: View {
    struct Pt: Identifiable { let id: Int; let day: Double; let tirz: Double; let reta: Double }

    static let points: [Pt] = (0...56).map { i in
        let day = Double(i) * 0.25
        return Pt(id: i, day: day, tirz: pow(0.5, day / 5), reta: pow(0.5, day / 6))
    }

    var body: some View {
        Chart {
            ForEach(Self.points) { p in
                LineMark(x: .value("Days", p.day), y: .value("Share", p.tirz), series: .value("Compound", "Tirzepatide"))
                    .foregroundStyle(LogColor.s3)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            }
            ForEach(Self.points) { p in
                LineMark(x: .value("Days", p.day), y: .value("Share", p.reta), series: .value("Compound", "Retatrutide"))
                    .foregroundStyle(LogColor.s2)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .chartXScale(domain: 0.0...14.0)
        .chartYScale(domain: 0.0...1.0)
        .chartXAxis {
            AxisMarks(values: [0.0, 7.0, 14.0]) { value in
                AxisGridLine().foregroundStyle(LogColor.grid)
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : (value.index == 2 ? .topTrailing : .top)) {
                    if let v = value.as(Double.self) { Text(v == 0 ? "Dose" : "Day \(Fmt.num(v, 0))") }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine().foregroundStyle(LogColor.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Fmt.num(v * 100, 0))%") }
                }
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Relative remaining after a dose, tirzepatide vs retatrutide half-life")
        .accessibilityValue("After 7 days: tirzepatide \(Fmt.num(pow(0.5, 7.0 / 5) * 100, 0))%, retatrutide \(Fmt.num(pow(0.5, 7.0 / 6) * 100, 0))%")
    }
}
