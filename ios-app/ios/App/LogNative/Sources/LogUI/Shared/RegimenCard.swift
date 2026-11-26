import SwiftUI
import LogCore

/// A daily peptide (log.regimen, such as tesamorelin): the dose, how often, where it stands, and
/// a one-tap log for today's shot. Meds shows every regimen; Today shows one only when a shot is
/// due today and not logged yet.
struct RegimenCard: View {
    @Environment(LogStore.self) private var store
    let status: RegimenStatus
    var compact = false
    /// Later steps of the same compound (1 mg to start, then 1.4 mg).
    var later: [Regimen] = []

    /// One card per compound: the step that's current or next, with the later steps listed in it.
    static func grouped(_ statuses: [RegimenStatus]) -> [(RegimenStatus, [Regimen])] {
        var seen: [String: Int] = [:]
        var out: [(RegimenStatus, [Regimen])] = []
        for s in statuses.sorted(by: { ($0.regimen.startOn ?? "") < ($1.regimen.startOn ?? "") }) where !s.finished {
            let c = s.regimen.compound ?? ""
            if let i = seen[c] { out[i].1.append(s.regimen) } else { seen[c] = out.count; out.append((s, [])) }
        }
        return out
    }

    @State private var busy = false
    @State private var message: MLMessage?

    var body: some View {
        let r = status.regimen
        LogCard(compact ? "\(r.name) tonight" : r.name) {
            Text(badge).font(.footnote.weight(.semibold)).foregroundStyle(badgeInk)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(badgeFill, in: Capsule())
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.num(r.doseMg, r.doseMg.map { $0.rounded() == $0 } == true ? 0 : 1)).font(.logNumber(34)).foregroundStyle(LogColor.ink)
                    Text("mg").font(.logNumber(17, weight: .semibold)).foregroundStyle(LogColor.ink2)
                    if let u = r.drawUnits {
                        Text("· \(Fmt.num(u, 0)) units").font(.logNumber(17, weight: .semibold)).foregroundStyle(LogColor.ink2)
                    }
                }
                Text(scheduleLine).font(.subheadline).foregroundStyle(LogColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(later, id: \.self) { r in
                    Text(thenLine(r)).font(.subheadline.weight(.medium)).foregroundStyle(LogColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !compact, let total = status.totalShots, status.daysToStart == 0, let n = status.shotNumber {
                    VStack(alignment: .leading, spacing: 6) {
                        ShareBar(share: Double(n) / Double(max(1, total)), color: LogColor.s3)
                            .frame(height: 8)
                        Text("Shot \(min(n, total)) of \(total) · \(status.taken) logged").font(.footnote).foregroundStyle(LogColor.ink2)
                    }
                }
                if status.missedRecently > 0 && status.daysToStart == 0 {
                    Text("\(status.missedRecently) planned \(status.missedRecently == 1 ? "day" : "days") in the last two weeks with nothing logged.")
                        .font(.footnote.weight(.medium)).foregroundStyle(LogColor.warnInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.dueToday && !status.loggedToday {
                    let site = store.dashboard.map { Analytics.nextBellySite($0, compound: r.compound ?? "") } ?? "Abd UR"
                    Button { log(site: site) } label: {
                        Text(busy ? "Saving…" : "Log today's \(Fmt.mg(r.doseMg)) mg · \(MLFmt.site(site))")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(LogColor.accent)
                    .disabled(busy)
                }
                MLMessageView(message: message)
                if !compact, let notes = r.notes, !notes.isEmpty {
                    Text(notes).font(.footnote).foregroundStyle(LogColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var badge: String {
        if status.finished { return "Done" }
        if status.daysToStart > 0 { return status.daysToStart == 1 ? "Starts tomorrow" : "In \(status.daysToStart) days" }
        if status.loggedToday { return "Logged today" }
        if status.dueToday { return "Due today" }
        return "Active"
    }
    private var badgeInk: Color {
        if status.loggedToday { return LogColor.goodInk }
        if status.dueToday && status.daysToStart == 0 { return LogColor.warnInk }
        return LogColor.ink2
    }
    private var badgeFill: Color {
        if status.loggedToday { return LogColor.goodSoft }
        if status.dueToday && status.daysToStart == 0 { return LogColor.warnSoft }
        return LogColor.surface2
    }

    /// "Daily at night · Dec 20 to Feb 28 · belly only"
    private var scheduleLine: String {
        let r = status.regimen
        var parts = [r.frequencyText.prefix(1).uppercased() + r.frequencyText.dropFirst() + (r.timeOfDay.map { " at \($0)" } ?? "")]
        if let s = r.startOn.map({ String($0.prefix(10)) }) {
            let from = LogTime.shortDate(LogTime.noon(s))
            if let e = r.endOn.map({ String($0.prefix(10)) }) {
                parts.append("\(from) to \(LogTime.shortDate(LogTime.noon(e)))")
            } else {
                parts.append("from \(from)")
            }
        }
        if let sites = r.sites, !sites.isEmpty { parts.append("\(sites) only") }
        if status.daysToStart == 0, let next = status.nextDay, !(status.dueToday && !status.loggedToday) {
            parts.append("next \(LogTime.shortDate(LogTime.noon(next)))")
        }
        return parts.joined(separator: " · ")
    }

    /// "Then 1.4 mg (14 units) daily, Jan 3 to Mar 4"
    private func thenLine(_ r: Regimen) -> String {
        var t = "Then \(Fmt.mg(r.doseMg)) mg"
        if let u = r.drawUnits { t += " (\(Fmt.num(u, 0)) units)" }
        t += " \(r.frequencyText)"
        if let s = r.startOn.map({ String($0.prefix(10)) }) {
            t += ", \(LogTime.shortDate(key: s))"
            if let e = r.endOn.map({ String($0.prefix(10)) }) { t += " to \(LogTime.shortDate(key: e))" }
        }
        return t
    }

    private func log(site: String) {
        guard !busy, let compound = status.regimen.compound else { return }
        var payload: [String: Any] = ["compound": compound, "skipped": false, "site": site]
        if let mg = status.regimen.doseMg { payload["dose_mg"] = MLNum.plain(mg) }
        if let u = status.regimen.drawUnits { payload["units"] = MLNum.plain(u.rounded()) }
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "dose_log", payload, success: "Logged \(status.regimen.name.lowercased()) \(Fmt.mg(status.regimen.doseMg)) mg.")
            busy = false
            withAnimation { message = m }
        }
    }
}
