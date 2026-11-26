import SwiftUI
import LogCore

/// The top of Meds: the next planned GLP-1 dose on a dark card, what to draw and where, and
/// (when it's due today or overdue) one tap to log it with the plan's numbers.
struct MLNextDoseHero: View {
    @Environment(LogStore.self) private var store
    let data: Dashboard
    @State private var busy = false
    @State private var message: MLMessage?

    static func shows(_ d: Dashboard) -> Bool { Analytics.nextPlanned(d) != nil }

    var body: some View {
        if let row = Analytics.nextPlanned(data) {
            let now = Date()
            let days = LogTime.dayDiff(row.plannedOn, LogTime.today(now))
            let due = days <= 0
            let site = Analytics.siteRotation(data).next
            VStack(alignment: .leading, spacing: 6) {
                Text(whenLine(days)).font(.footnote.weight(.semibold))
                    .foregroundStyle(days < 0 ? LogColor.warn : LogColor.heroInk2)
                Text("\(MLFmt.cap(row.compound)) \(Fmt.mg(row.doseMg)) mg")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text(detail(row, site: site))
                    .font(.subheadline).foregroundStyle(LogColor.heroInk2)
                    .fixedSize(horizontal: false, vertical: true)
                if due {
                    Button { log(row, site: site) } label: {
                        Text(busy ? "Saving…" : "Log this dose now")
                            .font(.headline)
                            .foregroundStyle(LogColor.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .padding(.top, 10)
                    .accessibilityHint("Saves the planned dose at the current time")
                }
                if let message {
                    Text(message.text).font(.subheadline.weight(.medium))
                        .foregroundStyle(message.ok ? Color(red: 0.55, green: 0.9, blue: 0.7) : Color(red: 1, green: 0.6, blue: 0.55))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LogMetric.cardPad + 2)
            .background(LogColor.hero, in: RoundedRectangle(cornerRadius: LogMetric.cardRadius, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    private func whenLine(_ days: Int) -> String {
        if days < 0 { return "Overdue · planned \(MLFmt.daysWord(days))" }
        if days == 0 { return "Next dose · today" }
        return "Next dose · \(MLFmt.daysWord(days))"
    }

    /// "Sun, Nov 29 · 25 units · Right love handle · Crush 2.5 mg (25 u)"
    private func detail(_ row: DosePlanRow, site: String?) -> String {
        var parts = [MLFmt.day(LogTime.noon(row.plannedOn))]
        if let u = row.units { parts.append("\(Fmt.num(u, 0)) units") }
        if let site { parts.append(MLFmt.site(site)) }
        if let v = row.vialDraw, !v.isEmpty, !v.lowercased().hasPrefix("none") { parts.append(v) }
        return parts.joined(separator: " · ")
    }

    private func log(_ row: DosePlanRow, site: String?) {
        guard !busy, let compound = row.compound else { return }
        var payload: [String: Any] = ["compound": compound, "skipped": false]
        if let mg = row.doseMg { payload["dose_mg"] = MLNum.plain(mg) }
        if let u = row.units { payload["units"] = MLNum.plain(u) }
        if let site { payload["site"] = site }
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "dose_log", payload, success: "Logged \(compound) \(Fmt.mg(row.doseMg)) mg.")
            busy = false
            withAnimation { message = m }
        }
    }
}
