import SwiftUI
import LogCore

// MARK: Check-in prompt

/// "Checked in today" with a summary, or the evening prompt to check in (web renderCheckinNudge).
/// Today's prompt waits until 6 PM Central; past days can be filled in any time.
struct TodayCheckinNudge: View {
    let m: TodayModel
    let open: () -> Void

    static func shows(_ m: TodayModel) -> Bool {
        if let c = m.checkin, hasAnswers(c) { return true }
        return !(m.isToday && LogTime.hour(m.now) < 18)
    }

    static func hasAnswers(_ c: Checkin) -> Bool {
        c.ateVsUsual != nil || c.movedVsUsual != nil || c.doseFeel != nil || c.mood != nil || c.energy != nil || c.foodNoise != nil || c.sleepQuality != nil
    }

    var body: some View {
        if let c = m.checkin, Self.hasAnswers(c) {
            TodayCallout(title: m.isToday ? "Checked in today" : "Checked in", detail: Self.summary(c).isEmpty ? "Saved." : Self.summary(c), tone: .good) {
                TodayLink("Edit", color: LogColor.goodInk, action: open)
            }
        } else if Self.shows(m) {
            TodayCallout(title: m.isToday ? "No check-in yet today" : "No check-in this day", detail: "How you ate, moved, felt and slept.",
                         tone: m.isToday ? .steady : .plain) {
                Button("Check in", action: open)
                    .buttonStyle(.borderedProminent)
                    .tint(LogColor.accent)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private static let vs = ["less": "Less", "usual": "Usual", "more": "More"]
    private static let feel = ["strong": "Strong", "fading": "Fading", "not_feeling_it": "Not feeling it"]

    /// "Ate more, moved usual, dose feels strong. Mood 9, food noise 3, energy 8, sleep 4 out of 10."
    static func summary(_ c: Checkin) -> String {
        var bits: [String] = []
        if let a = c.ateVsUsual, !a.isEmpty { bits.append("ate \((vs[a] ?? a).lowercased())") }
        if let a = c.movedVsUsual, !a.isEmpty { bits.append("moved \((vs[a] ?? a).lowercased())") }
        if let f = c.doseFeel, !f.isEmpty { bits.append("dose feels \((feel[f] ?? f).lowercased())") }
        var scores: [String] = []
        if let v = c.mood { scores.append("mood \(TodayText.plain(v))") }
        if let v = c.foodNoise { scores.append("food noise \(TodayText.plain(v))") }
        if let v = c.energy { scores.append("energy \(TodayText.plain(v))") }
        if let v = c.sleepQuality { scores.append("sleep \(TodayText.plain(v))") }
        var parts: [String] = []
        if !bits.isEmpty { parts.append(TodayText.capitalize(bits.joined(separator: ", ")) + ".") }
        if !scores.isEmpty { parts.append(TodayText.capitalize(scores.joined(separator: ", ")) + " out of 10.") }
        return parts.joined(separator: " ")
    }
}

// MARK: Food thoughts and side effects

private struct Strength: Identifiable {
    let v: Int
    let label: String
    var id: Int { v }
}
private let strengths: [Strength] = [Strength(v: 1, label: "Passing thought"), Strength(v: 2, label: "Strong pull"), Strength(v: 3, label: "Craving")]
private let commonEffects = ["Nausea", "Constipation", "Reflux", "Fatigue", "Headache", "Low appetite"]

/// Today: one-tap food thoughts and a quick side effect (web renderFeelNow / renderQuickEffect).
/// A past day: what was logged, if anything.
struct TodayFeelNow: View {
    let m: TodayModel
    @Binding var effectOpen: Bool
    let busy: Bool
    let send: (_ action: String, _ payload: [String: Any], _ success: String) async -> Bool

    static func shows(_ m: TodayModel) -> Bool {
        m.isToday || !m.thoughts.isEmpty || !m.effects.isEmpty
    }

    var body: some View {
        let lastAt = m.thoughts.last?.thoughtDate
        if !m.isToday {
            if Self.shows(m) {
                LogCard("Food thoughts and side effects") {
                    TodayProps(rows: [
                        ("Food thoughts", thoughtsText(lastAt)),
                        ("Side effects", m.effects.isEmpty ? "None logged" : effectList),
                    ])
                }
            }
        } else {
            LogCard("Thinking about food?") {
                TodayLink(effectOpen ? "Close" : "Side effect?") { effectOpen.toggle() }
            } content: {
                TodayCaption("Tap when it happens. It shows when food noise peaks in your week.")
                HStack(spacing: 8) {
                    ForEach(strengths) { s in
                        Button {
                            Task { _ = await send("food_thought", ["strength": s.v], "Logged a food thought (\(s.label.lowercased())).") }
                        } label: {
                            Text(s.label)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(LogColor.ink)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .padding(.horizontal, 6)
                                .background(s.v == 3 ? AnyShapeStyle(LogColor.s2.opacity(0.18)) : AnyShapeStyle(LogColor.surface2),
                                            in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .opacity(busy ? 0.5 : 1)
                    }
                }
                TodayCaption(m.thoughts.isEmpty ? "None yet today." : "\(m.thoughts.count) today, last at \(lastAt.map(LogTime.time) ?? "—").")
                if effectOpen {
                    QuickEffect(busy: busy, send: send, done: { effectOpen = false })
                }
                if !m.effects.isEmpty {
                    TodayCaption("Side effects today: \(effectList).")
                }
            }
        }
    }

    private func thoughtsText(_ lastAt: Date?) -> String {
        if m.thoughts.isEmpty { return "None logged" }
        guard let lastAt else { return "\(m.thoughts.count)" }
        return "\(m.thoughts.count), last at \(LogTime.time(lastAt))"
    }

    private var effectList: String {
        m.effects.map { "\($0.effect ?? "—") \(TodayText.plain($0.severity))/10" }.joined(separator: ", ")
    }
}

/// Pick or type a side effect and how bad it is, saved with side_effect_upsert.
private struct QuickEffect: View {
    let busy: Bool
    let send: (_ action: String, _ payload: [String: Any], _ success: String) async -> Bool
    let done: () -> Void

    @State private var picked = ""
    @State private var typed = ""
    @State private var severity = 4.0
    @State private var error: String?
    @FocusState private var typing: Bool

    init(busy: Bool, send: @escaping (_ action: String, _ payload: [String: Any], _ success: String) async -> Bool, done: @escaping () -> Void) {
        self.busy = busy
        self.send = send
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(LogColor.hairline).frame(height: 1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(commonEffects, id: \.self) { e in
                    Button {
                        picked = picked == e ? "" : e
                        if !picked.isEmpty { typed = "" }
                    } label: {
                        Text(e)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(picked == e ? LogColor.surface : LogColor.ink)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(picked == e ? LogColor.ink : LogColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked == e ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Something else").font(.subheadline.weight(.medium)).foregroundStyle(LogColor.ink2)
                TextField("Or type one", text: $typed)
                    .focused($typing)
                    .submitLabel(.done)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: typed) { _, v in
                        if v.count > 80 { typed = String(v.prefix(80)) }
                        if !v.isEmpty { picked = "" }
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("How bad, 1 to 10").font(.subheadline.weight(.medium)).foregroundStyle(LogColor.ink2)
                    Spacer()
                    Text("\(Int(severity))").font(.logNumber(17)).foregroundStyle(LogColor.ink)
                }
                Slider(value: $severity, in: 1...10, step: 1)
                    .tint(LogColor.accent)
                    .accessibilityLabel("How bad, 1 to 10")
                    .accessibilityValue("\(Int(severity))")
            }
            if let error {
                Text(error).font(.subheadline.weight(.medium)).foregroundStyle(LogColor.critInk)
            }
            Button("Save side effect") { submit() }
                .buttonStyle(.borderedProminent)
                .tint(LogColor.accent)
                .font(.body.weight(.semibold))
                .disabled(busy)
        }
        .onAppear {
            if TodayDebug.open == "effect" { picked = "Nausea" }
        }
    }

    private func submit() {
        let effect = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? picked : typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effect.isEmpty else { error = "Pick or type a side effect."; return }
        error = nil
        typing = false
        // The web sends the slider's value as text; log-write reads it either way.
        let payload: [String: Any] = ["effect": effect, "severity": String(Int(severity))]
        Task {
            if await send("side_effect_upsert", payload, "Logged \(effect.lowercased()).") { done() }
        }
    }
}

// MARK: Off your normal

/// Shows only when two or more recovery signals are off their 30-day normal (web renderOffNormal).
struct TodayOffNormal: View {
    let checks: [SignalCheck]

    static func shows(_ checks: [SignalCheck]) -> Bool { checks.filter(\.off).count >= 2 }

    var body: some View {
        if Self.shows(checks) {
            LogCard("Off your normal") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(checks.filter(\.off).count) of \(checks.count) recovery signals are off your normal")
                        .font(.body.weight(.semibold)).foregroundStyle(LogColor.ink)
                    Text("Common causes: a hard workout, short or late sleep, alcohol, a dose change, or getting sick.")
                        .font(.subheadline).foregroundStyle(LogColor.ink2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(LogColor.warnSoft, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Rectangle().fill(LogColor.hairline).frame(height: 1) }
                        SignalRow(c: c)
                    }
                }
            }
        }
    }
}

private struct SignalRow: View {
    let c: SignalCheck

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(c.spec.label).font(.subheadline).foregroundStyle(LogColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Self.fmt(c, c.value)).font(.logNumber(15, weight: .semibold)).foregroundStyle(LogColor.ink)
                Text("normal \(Self.fmt(c, c.median))").font(.caption.weight(.medium)).foregroundStyle(LogColor.ink2)
            }
            .fixedSize()
            Group {
                if c.off {
                    HStack(spacing: 3) {
                        Image(systemName: c.spec.up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8, weight: .bold))
                        Text(Self.diff(c))
                    }
                } else {
                    Text("Normal")
                }
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(c.off ? LogColor.warnInk : LogColor.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(c.off ? LogColor.warnSoft : LogColor.surface2, in: Capsule())
            .fixedSize()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private static func unit(_ c: SignalCheck) -> String {
        c.spec.unit == "/min" || c.spec.unit == "°F" ? c.spec.unit : " \(c.spec.unit)"
    }

    static func fmt(_ c: SignalCheck, _ v: Double) -> String { "\(Fmt.num(v, c.spec.digits))\(unit(c))" }

    /// "+8 bpm", "−42%", "+3.5/min" (web fmtSignalDiff)
    static func diff(_ c: SignalCheck) -> String {
        if c.spec.id == "hrv_ms" { return "\(Fmt.signed(c.diff / c.median * 100, 0))%" }
        return "\(Fmt.signed(c.diff, c.spec.digits))\(unit(c))"
    }
}

// MARK: Countdowns

/// Next dose and the retatrutide switch, in days (web renderCountdowns).
struct TodayCountdowns: View {
    let m: TodayModel

    private struct Count: Identifiable {
        let label: String
        let date: Date
        var id: String { label }
    }

    private var counts: [Count] {
        let next = Analytics.plannedNextDose(m.d)
        let switchAt = Analytics.retaSwitchAt(m.d)
        var out: [Count] = []
        if let next {
            out.append(Count(label: "Next dose", date: next))
            if LogTime.daysUntil(LogTime.retaStart, now: m.now) >= 0 { out.append(Count(label: "Retatrutide", date: switchAt)) }
        } else if LogTime.daysUntil(switchAt, now: m.now) >= 0 {
            out.append(Count(label: "Retatrutide", date: switchAt))
        }
        return out
    }

    var body: some View {
        let list = counts
        if !list.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(list) { c in tile(c) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Coming up")
        }
    }

    private func tile(_ c: Count) -> some View {
        let n = LogTime.daysUntil(c.date, now: m.now)
        return VStack(alignment: .leading, spacing: 2) {
            Text(c.label).font(.footnote.weight(.medium)).foregroundStyle(LogColor.ink2).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(n <= 0 ? (n == 0 ? "Today" : "Done") : "\(n)").font(.logNumber(30, weight: .semibold))
                    .foregroundStyle(LogColor.ink)
                if n > 0 { Text(n == 1 ? " day" : " days").font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink2) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(LogTime.weekdayDate(c.date)).font(.footnote).foregroundStyle(LogColor.ink2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LogColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Verdict

/// Is it working? Weight against the start, the recent pace and a stall check (web verdictCard).
struct TodayVerdict: View {
    let m: TodayModel

    struct Result {
        var label: String
        var tone: TodayTone
        var receipts: [String]
    }

    static func make(_ m: TodayModel) -> Result {
        guard let j = m.journey else { return Result(label: "Building", tone: .steady, receipts: ["Needs a weigh-in to start a verdict."]) }
        let doses = m.d.doses.filter { $0.skipped != true }
        var receipts: [String] = [
            "Current weight \(Fmt.num(j.current.lb, 1)) lb as of \(LogTime.weekdayDate(j.current.at)).",
            "\(j.changeStart <= 0 ? "Down" : "Up") \(Fmt.num(abs(j.changeStart), 1)) lb from your \(Fmt.num(j.startLb, 1)) lb start.",
        ]
        if let rp = m.pace {
            receipts.append("\(Fmt.signed(rp.weekly)) lb a week over the last 4 weeks of weigh-ins (\(Fmt.num(abs(rp.weekly / j.current.lb) * 100, 1))% of body weight).")
        }
        receipts.append("\(TodayText.plural(doses.count, "dose")) logged.")
        let daysOn = m.now.timeIntervalSince(LogTime.tirzStart) / 86400
        let stall = Analytics.stallCheck(m.points, now: m.now)
        let change = j.changeStart
        if daysOn < 10 && change > -2 {
            receipts.append("Still early in the first cycles.")
            return Result(label: "Building", tone: .steady, receipts: receipts)
        }
        if stall.stalled {
            receipts.append("Smoothed weight has been roughly flat for 3 weeks (\(Fmt.num(stall.fromLb, 1)) to \(Fmt.num(stall.toLb, 1)) lb).")
            return Result(label: "Worth watching", tone: .watch, receipts: receipts)
        }
        if change <= -8 {
            receipts.append("Weight has moved down clearly since your start.")
            return Result(label: "Working", tone: .good, receipts: receipts)
        }
        if abs(change) < 2 { return Result(label: "Steady", tone: .steady, receipts: receipts) }
        if change > 2 {
            receipts.append("Weight is up since your start.")
            return Result(label: "Worth watching", tone: .watch, receipts: receipts)
        }
        return Result(label: "Working", tone: .good, receipts: receipts)
    }

    var body: some View {
        let v = Self.make(m)
        LogCard("Verdict") {
            Text(v.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(v.tone.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(v.tone.soft, in: Capsule())
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(v.receipts.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(v.tone == .good ? LogColor.good : v.tone == .watch ? LogColor.warn : LogColor.axis)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                        Text(r).font(.subheadline).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: Medication

/// Today: the modeled level now, last and next dose, next site (web renderMedSummary).
struct TodayMedSummary: View {
    let m: TodayModel

    var body: some View {
        let d = m.d
        let level = Analytics.remaining(at: m.now, doses: d.doses, protocols: d.protocols)
        let last = d.doses.last(where: { $0.skipped != true })
        LogCard("Medication") {
            TodayLink("Details") { TodayTabs.select(1) }
        } content: {
            MedLevel(level: level, detail: "Estimated in your system now, from a half-life model")
            TodayProps(rows: [
                ("Last dose", lastText(last)),
                ("Next dose", nextText),
                ("Next site", Sites.label(Analytics.nextSite(d))),
            ])
        }
    }

    private func lastText(_ dose: Dose?) -> String {
        guard let dose, let at = dose.takenDate else { return "—" }
        return "\(Fmt.num(dose.doseMg, 1)) mg \(TodayText.capitalize(dose.compound ?? "")), \(LogTime.weekdayDate(at))"
    }

    private var nextText: String {
        if let plan = Analytics.nextPlanned(m.d, now: m.now) {
            let day = LogTime.noon(plan.plannedOn)
            let text = "\(TodayText.capitalize(plan.compound ?? "")) \(Fmt.num(plan.doseMg, 1)) mg\(plan.units.map { " (\(Fmt.num($0, 0)) units)" } ?? "")"
            return "\(text), \(LogTime.weekdayDate(day)) (\(TodayText.daysWord(LogTime.daysUntil(day, now: m.now))))"
        }
        if let next = Analytics.plannedNextDose(m.d) {
            return "\(LogTime.weekdayDate(next)), \(TodayText.daysWord(LogTime.daysUntil(next, now: m.now)))"
        }
        return "Retatrutide starts \(LogTime.weekdayDate(LogTime.retaStart))"
    }
}

/// A past day: the level at 9 PM and that day's doses (web renderDayMeds). Nothing before the first dose.
struct TodayDayMeds: View {
    let m: TodayModel

    static func shows(_ m: TodayModel) -> Bool {
        guard let first = m.d.doses.first(where: { $0.skipped != true && $0.takenDate != nil }), let at = first.takenDate else { return false }
        return LogTime.dayKey(at) <= m.key
    }

    var body: some View {
        if Self.shows(m) {
            let d = m.d
            let that = d.doses.filter { $0.takenDate.map(LogTime.dayKey) == m.key }
            let at = min(m.now, LogTime.noon(m.key).addingTimeInterval(9 * 3600))
            LogCard("Medication") {
                MedLevel(level: Analytics.remaining(at: at, doses: d.doses, protocols: d.protocols), detail: "Estimated in your system at 9 PM that day")
                TodayProps(rows: [("Dose that day", that.isEmpty ? "None" : that.map(Self.doseText).joined(separator: "; "))])
            }
        }
    }

    private static func doseText(_ dose: Dose) -> String {
        if dose.skipped == true { return "Skipped" }
        let site = dose.site.map { ", \(Sites.label($0))" } ?? ""
        return "\(Fmt.num(dose.doseMg, 1)) mg \(TodayText.capitalize(dose.compound ?? ""))\(site)"
    }
}

private struct MedLevel: View {
    let level: Double
    let detail: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 40

    init(level: Double, detail: String) {
        self.level = level
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.num(level, 2)).font(.logNumber(min(size, 56), weight: .semibold)).foregroundStyle(LogColor.ink)
                Text("mg").font(.logNumber(18, weight: .semibold)).foregroundStyle(LogColor.ink2)
            }
            Text(detail).font(.footnote).foregroundStyle(LogColor.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}
