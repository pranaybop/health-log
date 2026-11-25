import SwiftUI
import LogCore

// The Log tab's forms (web: forms.js). Each sends exactly the web form's action and payload: the
// same keys, numbers as the typed text where the web sends input values, and the same checks and
// wording. Fields keep what was typed if a save fails, and reset after a save like the web's redraw.

enum MLTime {
    /// Like JavaScript's toISOString: "2026-11-25T14:30:00.000Z".
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// Weigh-in (web: renderWeighIn): weight_lb as typed, optional notes.
struct MLWeighInCard: View {
    @Environment(LogStore.self) private var store
    @State private var weight = ""
    @State private var notes = ""
    @State private var busy = false
    @State private var message: MLMessage?

    var body: some View {
        LogCard("Weigh-in") {
            MLInput(label: "Weight (lb)", text: $weight, placeholder: "0.0", keyboard: .decimalPad, big: true)
            MLInput(label: "Notes", text: $notes, maxLength: 200)
            MLSaveButton(title: "Save weigh-in", busy: busy, action: save)
            MLMessageView(message: message)
        }
        .modifier(MLAutoClear(message: $message))
    }

    private func save() {
        guard !busy else { return }
        let w = MLNum.text(weight)
        if w.isEmpty { withAnimation { message = MLMessage(ok: false, text: "Enter a weight.") }; return }
        var payload: [String: Any] = ["weight_lb": w]
        let n = trimmed(notes)
        if !n.isEmpty { payload["notes"] = n }
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "weigh_in", payload, success: "Logged \(w) lb.")
            busy = false
            withAnimation { message = m }
            if m.ok { weight = ""; notes = "" }
        }
    }
}

/// Earn It (web: renderEarnIt): today's earned flag.
struct MLEarnItCard: View {
    @Environment(LogStore.self) private var store
    @State private var busy = false
    @State private var message: MLMessage?

    var body: some View {
        let cur = store.dashboard?.checkins.first { $0.day == LogTime.today() }
        let status = cur?.earned == true ? "You earned it today." : cur?.earned == false ? "Marked as not earned today." : "Not marked yet today."
        LogCard("Earn It") {
            Caption(status)
            HStack(spacing: 10) {
                Button { send(true) } label: {
                    Text("Yes, earned it").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(LogColor.accent)
                Button { send(false) } label: {
                    Text("Not today").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(LogColor.accent)
            }
            .disabled(busy)
            MLMessageView(message: message)
        }
        .modifier(MLAutoClear(message: $message))
    }

    private func send(_ earned: Bool) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "earn_it", ["earned": earned], success: earned ? "Earned it." : "Marked as not earned.")
            busy = false
            withAnimation { message = m }
        }
    }
}

/// Log a dose (web: renderDoseForm): compound, mg, units, site (the suggested next one picked),
/// time, skipped and notes. The defaults follow the active protocol and the site rotation.
struct MLDoseForm: View {
    @Binding var open: Bool
    @Environment(LogStore.self) private var store
    // nil means "the default from the data", so defaults follow a refresh and come back after a save.
    @State private var compound: String?
    @State private var mgText: String?
    @State private var unitsText: String?
    @State private var site: String?
    @State private var skipped = false
    @State private var notes = ""
    @State private var takenAt = Date()
    @State private var timeEdited = false
    @State private var busy = false
    @State private var message: MLMessage?

    static let compounds = [MLOption(value: "tirzepatide", label: "Tirzepatide"), MLOption(value: "retatrutide", label: "Retatrutide")]

    private var active: ProtocolRow? { store.dashboard?.protocols.first { $0.status == "active" } }
    private var rot: SiteRotation? { store.dashboard.map { Analytics.siteRotation($0) } }
    private var defaultCompound: String {
        let c = active?.compound ?? "tirzepatide"
        return Self.compounds.contains { $0.value == c } ? c : "tirzepatide"
    }
    private var compoundValue: String { compound ?? defaultCompound }
    private var mgValue: String { mgText ?? MLNum.plain(active?.typicalDoseMg ?? 3) }
    private var unitsValue: String { unitsText ?? MLNum.plain(active?.units) }
    private var siteValue: String { site ?? rot?.next ?? rot?.lastSite ?? "" }

    var body: some View {
        let hint = rot?.next.map { "Suggested site: \(MLFmt.site($0))" } ?? "Pick the site you used"
        MLFold("Log a dose", hint: hint, open: $open) {
            VStack(alignment: .leading, spacing: 16) {
                MLField("Compound") {
                    Picker("Compound", selection: Binding(get: { compoundValue }, set: { compound = $0 })) {
                        ForEach(Self.compounds, id: \.self) { o in Text(o.label).tag(o.value) }
                    }
                    .pickerStyle(.segmented)
                }
                HStack(alignment: .top, spacing: 12) {
                    MLInput(label: "Dose (mg)", text: Binding(get: { mgValue }, set: { mgText = $0 }), keyboard: .decimalPad)
                    MLInput(label: "Units (optional)", text: Binding(get: { unitsValue }, set: { unitsText = $0 }), keyboard: .numberPad)
                }
                MLField("Injection site") {
                    MLChips(options: Sites.all.map { MLOption(value: $0, label: MLFmt.site($0)) },
                            value: Binding(get: { siteValue }, set: { site = $0 }), grid: true)
                }
                timeRow
                Toggle(isOn: $skipped) {
                    Text("Mark as skipped").foregroundStyle(LogColor.ink)
                }
                .tint(LogColor.good)
                MLInput(label: "Notes", text: $notes)
                MLSaveButton(title: "Save dose", busy: busy, action: save)
                MLMessageView(message: message)
            }
        }
        .modifier(MLAutoClear(message: $message))
    }

    private var timeRow: some View {
        HStack(spacing: 10) {
            Text("Time").font(.subheadline).foregroundStyle(LogColor.ink2)
            Spacer(minLength: 8)
            if timeEdited {
                DatePicker("Time taken", selection: $takenAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .environment(\.timeZone, LogTime.zone)
                Button("Now") { timeEdited = false }
                    .font(.subheadline)
            } else {
                Text("Now").font(.subheadline).foregroundStyle(LogColor.ink)
                Button("Change") {
                    takenAt = Date()
                    timeEdited = true
                }
                .font(.subheadline)
            }
        }
    }

    private func save() {
        guard !busy else { return }
        let comp = compoundValue
        let dose = MLNum.text(mgValue)
        let u = MLNum.text(unitsValue)
        let n = trimmed(notes)
        var payload: [String: Any] = ["compound": comp, "skipped": skipped]
        if !skipped {
            if dose.isEmpty {
                withAnimation { message = MLMessage(ok: false, text: "Enter a dose in mg, or mark the shot as skipped.") }
                return
            }
            payload["dose_mg"] = dose
        } else if !dose.isEmpty {
            payload["dose_mg"] = dose
        }
        if !u.isEmpty { payload["units"] = u }
        if !siteValue.isEmpty { payload["site"] = siteValue }
        if !n.isEmpty { payload["notes"] = n }
        if timeEdited { payload["taken_at"] = MLTime.iso(min(takenAt, Date())) }
        let success = skipped ? "Logged a skipped dose." : "Logged \(comp) \(dose) mg."
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "dose_log", payload, success: success)
            busy = false
            withAnimation { message = m }
            if m.ok {
                compound = nil; mgText = nil; unitsText = nil; site = nil
                skipped = false; notes = ""; timeEdited = false
            }
        }
    }
}

/// Side effect (web: renderSideEffectForm): a name and a 1-10 severity (starts at 5).
struct MLSideEffectForm: View {
    @Binding var open: Bool
    @Environment(LogStore.self) private var store
    @State private var effect = ""
    @State private var severity: Int? = 5
    @State private var notes = ""
    @State private var busy = false
    @State private var message: MLMessage?

    var body: some View {
        MLFold("Side effect", hint: "Name it and rate it 1 to 10", open: $open) {
            VStack(alignment: .leading, spacing: 16) {
                MLInput(label: "Effect", text: $effect, placeholder: "Headache, nausea…", maxLength: 80)
                MLScale(label: "Severity", value: $severity)
                MLInput(label: "Notes", text: $notes)
                MLSaveButton(title: "Save side effect", busy: busy, action: save)
                MLMessageView(message: message)
            }
        }
        .modifier(MLAutoClear(message: $message))
    }

    private func save() {
        guard !busy else { return }
        let name = trimmed(effect)
        if name.isEmpty { withAnimation { message = MLMessage(ok: false, text: "Name the side effect.") }; return }
        var payload: [String: Any] = ["effect": name, "severity": String(severity ?? 5)]
        let n = trimmed(notes)
        if !n.isEmpty { payload["notes"] = n }
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "side_effect_upsert", payload, success: "Logged \(name).")
            busy = false
            withAnimation { message = m }
            if m.ok { effect = ""; severity = 5; notes = "" }
        }
    }
}

/// Measurement (web: renderMeasurementForm): metric, value as typed, unit.
struct MLMeasurementForm: View {
    @Binding var open: Bool
    @Environment(LogStore.self) private var store
    @State private var metric = "waist"
    @State private var value = ""
    @State private var unit = "in"
    @State private var busy = false
    @State private var message: MLMessage?

    static let metrics = [
        MLOption(value: "waist", label: "Waist"), MLOption(value: "chest", label: "Chest"),
        MLOption(value: "hip", label: "Hip"), MLOption(value: "neck", label: "Neck"),
        MLOption(value: "thigh", label: "Thigh"), MLOption(value: "arm", label: "Arm"),
        MLOption(value: "body_fat_pct", label: "Body fat %"), MLOption(value: "lean_mass_lb", label: "Lean mass (lb)"),
    ]
    static let units = ["in", "cm", "lb", "kg", "%"]

    var body: some View {
        MLFold("Measurement", hint: "Waist, chest, hip and more", open: $open) {
            VStack(alignment: .leading, spacing: 16) {
                MLField("Metric") {
                    Picker("Metric", selection: $metric) {
                        ForEach(Self.metrics, id: \.self) { o in Text(o.label).tag(o.value) }
                    }
                    .pickerStyle(.menu)
                    .tint(LogColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(MLInputStyle())
                }
                MLInput(label: "Value", text: $value, keyboard: .decimalPad)
                MLField("Unit") {
                    Picker("Unit", selection: $unit) {
                        ForEach(Self.units, id: \.self) { u in Text(u).tag(u) }
                    }
                    .pickerStyle(.segmented)
                }
                MLSaveButton(title: "Save measurement", busy: busy, action: save)
                MLMessageView(message: message)
            }
        }
        .modifier(MLAutoClear(message: $message))
    }

    private func save() {
        guard !busy else { return }
        let v = MLNum.text(value)
        if v.isEmpty { withAnimation { message = MLMessage(ok: false, text: "Enter a measurement.") }; return }
        let payload: [String: Any] = ["metric": metric, "value": v, "unit": unit]
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "measurement", payload, success: "Saved measurement.")
            busy = false
            withAnimation { message = m }
            if m.ok { metric = "waist"; value = ""; unit = "in" }
        }
    }
}

/// Start a vial (web: renderVialForm): total mg or total units required.
struct MLVialForm: View {
    @Binding var open: Bool
    @Environment(LogStore.self) private var store
    @State private var compound = "tirzepatide"
    @State private var label = ""
    @State private var totalMg = ""
    @State private var totalUnits = ""
    @State private var conc = ""
    @State private var expires: Date?
    @State private var notes = ""
    @State private var busy = false
    @State private var message: MLMessage?

    var body: some View {
        MLFold("Start a vial", hint: "Track supply runway", open: $open) {
            VStack(alignment: .leading, spacing: 16) {
                MLField("Compound") {
                    Picker("Compound", selection: $compound) {
                        ForEach(MLDoseForm.compounds, id: \.self) { o in Text(o.label).tag(o.value) }
                    }
                    .pickerStyle(.segmented)
                }
                MLInput(label: "Label (optional)", text: $label, maxLength: 80)
                HStack(alignment: .top, spacing: 12) {
                    MLInput(label: "Total mg", text: $totalMg, keyboard: .decimalPad)
                    MLInput(label: "Total units", text: $totalUnits, keyboard: .numberPad)
                }
                MLInput(label: "Concentration (mg/mL, optional)", text: $conc, keyboard: .decimalPad)
                MLField("Expires on") {
                    HStack {
                        if let e = expires {
                            DatePicker("Expires on", selection: Binding(get: { e }, set: { expires = $0 }), displayedComponents: .date)
                                .labelsHidden()
                                .environment(\.timeZone, LogTime.zone)
                            Spacer()
                            Button("Clear") { expires = nil }.font(.subheadline)
                        } else {
                            Button("Add a date") { expires = Date() }.font(.subheadline)
                            Spacer()
                        }
                    }
                }
                MLInput(label: "Notes", text: $notes)
                MLSaveButton(title: "Save vial", busy: busy, action: save)
                MLMessageView(message: message)
            }
        }
        .modifier(MLAutoClear(message: $message))
    }

    private func save() {
        guard !busy else { return }
        var payload: [String: Any] = ["compound": compound]
        let l = trimmed(label)
        if !l.isEmpty { payload["label"] = l }
        let mg = MLNum.text(totalMg)
        if !mg.isEmpty { payload["total_mg"] = mg }
        let u = MLNum.text(totalUnits)
        if !u.isEmpty { payload["total_units"] = u }
        let c = MLNum.text(conc)
        if !c.isEmpty { payload["concentration_mg_per_ml"] = c }
        if let e = expires { payload["expired_on"] = LogTime.dayKey(e) }
        let n = trimmed(notes)
        if !n.isEmpty { payload["notes"] = n }
        if mg.isEmpty && u.isEmpty {
            withAnimation { message = MLMessage(ok: false, text: "Enter total mg or total units.") }
            return
        }
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "vial_start", payload, success: "Vial added.")
            busy = false
            withAnimation { message = m }
            if m.ok {
                compound = "tirzepatide"; label = ""; totalMg = ""; totalUnits = ""; conc = ""; expires = nil; notes = ""
            }
        }
    }
}

/// Reconstitution calculator (web: renderReconCalc): units to draw for a dose. Nothing is saved.
struct MLReconForm: View {
    @Binding var open: Bool
    @Environment(LogStore.self) private var store
    @State private var vialMg = ""
    @State private var diluent = "1"
    @State private var wantMg = ""

    static let idle = "This stays on your device and is not saved. Assumes 100 units = 1 mL."

    var body: some View {
        MLFold("Reconstitution calculator", hint: "Units to draw for a dose. Not saved", open: $open) {
            VStack(alignment: .leading, spacing: 16) {
                Caption(Self.mixNote(store.dashboard))
                MLInput(label: "Vial amount (mg)", text: $vialMg, keyboard: .decimalPad)
                MLInput(label: "Diluent (mL)", text: $diluent, keyboard: .decimalPad)
                MLInput(label: "Desired dose (mg)", text: $wantMg, keyboard: .decimalPad)
                Text(result)
                    .font(.subheadline)
                    .foregroundStyle(LogColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var result: String {
        let v = MLNum.double(vialMg) ?? 0
        let m = MLNum.double(diluent) ?? 0
        let w = MLNum.double(wantMg) ?? 0
        guard v > 0, m > 0, w > 0 else { return Self.idle }
        let units = (w / v) * m * 100
        let conc = v / m
        return "Draw \(Fmt.num(units, 1)) units. That’s \(Fmt.num(conc, 2)) mg/mL after mixing. Not saved."
    }

    /// web: retaMixNote
    static func mixNote(_ d: Dashboard?) -> String {
        let p = d.flatMap { Analytics.protocolRow($0, "retatrutide") }
        guard let units = p?.units, let mg = p?.typicalDoseMg, units > 0 else {
            return "For the retatrutide start: mix the vial with 1 mL, then use the units in your plan."
        }
        let conc = mg / (units / 100)
        return "For the retatrutide start: \(Fmt.num(units, 0)) units is \(Fmt.num(mg, 1)) mg at \(Fmt.num(conc, 0)) mg/mL (a \(Fmt.num(conc, 0)) mg vial mixed with 1 mL)."
    }
}

/// The app version line (web: renderAppVersion), from the bundle.
enum MLAppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let v = info["CFBundleShortVersionString"] as? String, !v.isEmpty, v != "dev" else { return "Log, development copy" }
        let b = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : " (build \($0))" } ?? ""
        return "Log \(v)\(b)"
    }
}
