import SwiftUI
import LogCore

struct MLDosePlanCard: View {
    let data: Dashboard
    @Environment(LogStore.self) private var store
    @State private var reminders = ReminderModel.shared
    @State private var busy = false
    @State private var message: MLMessage?

    static func shows(_ d: Dashboard) -> Bool { !Analytics.planRows(d).isEmpty }

    static func doseText(_ r: DosePlanRow) -> String {
        let units = r.units.map { " (\(Fmt.num($0, 0)) units)" } ?? ""
        return "\(MLFmt.cap(r.compound)) \(Fmt.num(r.doseMg, 1)) mg\(units)"
    }

    private var now: Date { TodayDebug.now ?? Date() }

    var body: some View {
        let rows = Analytics.planRows(data)
        let next = Analytics.nextPlanned(data)
        let steps = Analytics.planSteps(rows)
        let reta = rows.filter { $0.compound == "retatrutide" }
        let total = reta.reduce(0.0) { $0 + ($1.doseMg ?? 0) }
        let today = LogTime.today(now)
        let overdue = next.map { Analytics.planIsOverdue($0, now: now) } ?? false
        let cutoff = next?.plannedOn ?? "9999"
        let used = reta.filter { $0.plannedOn < cutoff }.reduce(0.0) { $0 + ($1.doseMg ?? 0) }
        let stepUp: DosePlanRow? = next.flatMap { n in
            rows.first { $0.plannedOn > n.plannedOn && $0.compound == n.compound && ($0.doseMg ?? 0) > (n.doseMg ?? 0) }
        }
        let current: Int? = next.flatMap { n in steps.firstIndex { n.plannedOn >= $0.from && n.plannedOn <= $0.to } }
        LogCard("Dose plan", accessory: {
            if overdue { MLBadge("Overdue", .watch) }
        }) {
            if let next {
                let week = next.week.map { ", week \(Fmt.num($0, 0)) of \(reta.count)" } ?? ""
                Text("\(overdue ? "Overdue" : "Next"): \(Self.doseText(next))\(week).")
                    .font(.headline).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    PropRow(overdue ? "Was due" : "When", when(next.plannedOn))
                    if let draw = next.vialDraw, !draw.isEmpty { MLHairline(); PropRow("Draw from", draw) }
                    if let note = next.notes, !note.isEmpty { MLHairline(); PropRow("Note", note) }
                    if let s = stepUp {
                        MLHairline()
                        PropRow("Next step-up", "\(Fmt.num(s.doseMg, 1)) mg\(s.units.map { " (\(Fmt.num($0, 0)) units)" } ?? "") on \(MLFmt.day(LogTime.noon(s.plannedOn)))")
                    }
                    if !reta.isEmpty { MLHairline(); PropRow("Retatrutide used", "\(Fmt.num(used, 1)) of \(Fmt.num(total, 0)) mg planned") }
                }
                if next.plannedOn <= today {
                    skipButton(next)
                    if reminders.offersShotPrompt { remindOffer }
                }
            } else {
                Text("Every planned dose is done.").font(.headline).foregroundStyle(LogColor.ink)
            }
            stepsTable(steps, current: current, today: today)
            Caption("From your titration sheet. The plan is a guide; what you actually take is what you log. 1 mg = 10 units at 10 mg/mL.")
        }
        .modifier(MLAutoClear(message: $message))
    }

    private var remindOffer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remind you at \(ReminderSettings.clock(reminders.settings.shotHour, reminders.settings.shotMinute)), including while this dose is still open.")
                .font(.footnote).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Remind me") { Task { await reminders.enableShot() } }
                    .buttonStyle(.borderedProminent)
                    .tint(LogColor.accent)
                Button("Not now") { reminders.dismissShotPrompt() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func skipButton(_ row: DosePlanRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { skip(row) } label: {
                Text("Skip this dose").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            MLMessageView(message: message)
        }
    }

    /// Same dose_log write as the dose form's skip switch, dated on the planned day so this week clears.
    private func skip(_ row: DosePlanRow) {
        guard !busy else { return }
        var payload: [String: Any] = [
            "compound": row.compound ?? "",
            "skipped": true,
            "taken_at": MLTime.iso(LogTime.noon(row.plannedOn)),
            "notes": "Skipped planned dose",
        ]
        if let mg = row.doseMg { payload["dose_mg"] = mg }
        if let units = row.units { payload["units"] = units }
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "dose_log", payload, success: "Skipped the planned dose.")
            busy = false
            withAnimation { message = m }
        }
    }

    private func when(_ key: String) -> String {
        let d = LogTime.noon(key)
        return "\(MLFmt.day(d)), \(TodayText.daysWord(MLFmt.days(until: d, now: now)))"
    }

    private func stepsTable(_ steps: [PlanStep], current: Int?, today: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Dose").frame(maxWidth: .infinity, alignment: .leading)
                Text("Sundays").frame(maxWidth: .infinity, alignment: .leading)
                Text("Weeks").frame(minWidth: 48, alignment: .trailing)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(LogColor.ink2)
            .padding(.bottom, 6)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                stepRow(s, on: i == current, done: i != current && s.to < today)
            }
        }
    }

    private func stepRow(_ s: PlanStep, on: Bool, done: Bool) -> some View {
        VStack(spacing: 0) {
            MLHairline()
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    if on { RoundedRectangle(cornerRadius: 1.5).fill(LogColor.accent).frame(width: 3, height: 16) }
                    Text(stepDose(s))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(s.from == s.to ? MLFmt.shortKey(s.from) : "\(MLFmt.shortKey(s.from)) – \(MLFmt.shortKey(s.to))")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(s.weeks)").font(.logNumber(15, weight: on ? .bold : .regular))
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .foregroundStyle(done ? LogColor.ink2 : LogColor.ink)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func stepDose(_ s: PlanStep) -> String {
        let prefix = s.compound == "tirzepatide" ? "Tirz " : ""
        let units = s.units.map { ", \(Fmt.num($0, 0)) u" } ?? ""
        return "\(prefix)\(Fmt.num(s.doseMg, 1)) mg\(units)"
    }
}
