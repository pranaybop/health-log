import SwiftUI
import LogCore

/// The daily check-in form: how you ate, moved, felt and slept
/// for one day, saved with checkin_upsert (which merges
/// the fields sent into that day's row).
///
/// Today presents it in a sheet from its check-in prompt; Log shows it in its "Today's check-in"
/// card. It starts from that day's saved answers and keeps what you type through refreshes.
public struct CheckinForm: View {
    /// The day it's for (yyyy-MM-dd, profile zone).
    public var day: String
    /// Called after a successful save (Today closes its sheet).
    public var onSaved: (() -> Void)?

    @Environment(LogStore.self) private var store
    @Environment(\.mlKeyboardDoneShown) private var keyboardDoneShown

    @State private var ate = ""
    @State private var moved = ""
    @State private var feel = ""
    @State private var mood: Int?
    @State private var foodNoise: Int?
    @State private var energy: Int?
    @State private var sleepQuality: Int?
    @State private var sleepHours = ""
    @State private var exercise = ""
    @State private var steps = ""
    @State private var restingHr = ""
    @State private var activeCalories = ""
    @State private var notes = ""
    @State private var showHealth = false
    @State private var loadedDay: String?
    @State private var loadedRow = false
    @State private var busy = false
    @State private var message: MLMessage?

    public init(day: String, onSaved: (() -> Void)? = nil) {
        self.day = day
        self.onSaved = onSaved
    }

    static let ateOptions = [MLOption(value: "less", label: "Ate less"), MLOption(value: "usual", label: "Usual"), MLOption(value: "more", label: "Ate more")]
    static let movedOptions = [MLOption(value: "less", label: "Moved less"), MLOption(value: "usual", label: "Usual"), MLOption(value: "more", label: "Moved more")]
    static let feelOptions = [MLOption(value: "strong", label: "Strong"), MLOption(value: "fading", label: "Fading"), MLOption(value: "not_feeling_it", label: "Not feeling it")]

    public var body: some View {
        form
            .onAppear { load(force: false) }
            .onChange(of: day) { _, _ in load(force: true) }
            .onChange(of: store.dashboard?.asOf) { _, _ in load(force: false) }
            .modifier(MLAutoClear(message: $message))
            .modifier(MLCheckinKeyboardDone(needed: !keyboardDoneShown))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                MLField("Ate vs usual") { MLChips(options: Self.ateOptions, value: $ate) }
                MLField("Moved vs usual") { MLChips(options: Self.movedOptions, value: $moved) }
                MLField("Dose feel") { MLChips(options: Self.feelOptions, value: $feel) }
            }
            VStack(alignment: .leading, spacing: 12) {
                MLScale(label: "Mood", value: $mood)
                MLScale(label: "Food noise", value: $foodNoise)
                MLScale(label: "Energy", value: $energy)
                MLScale(label: "Sleep quality", value: $sleepQuality)
            }
            HStack(alignment: .top, spacing: 12) {
                MLInput(label: "Sleep hours", text: $sleepHours, keyboard: .decimalPad)
                MLInput(label: "Exercise minutes", text: $exercise, keyboard: .numberPad)
            }
            DisclosureGroup(isExpanded: $showHealth) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        MLInput(label: "Steps", text: $steps, keyboard: .numberPad)
                        MLInput(label: "Resting HR", text: $restingHr, keyboard: .numberPad)
                    }
                    MLInput(label: "Active calories", text: $activeCalories, keyboard: .numberPad)
                }
                .padding(.top, 10)
            } label: {
                Text("Health numbers (optional)").font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink)
            }
            .tint(LogColor.ink2)
            MLField("Notes") {
                TextField("", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
                    .foregroundStyle(LogColor.ink)
                    .modifier(MLInputStyle())
                    .accessibilityLabel("Notes")
            }
            MLSaveButton(title: "Save check-in", busy: busy, action: save)
            MLMessageView(message: message)
        }
    }

    // MARK: Loading the saved answers

    private var isBlank: Bool {
        ate.isEmpty && moved.isEmpty && feel.isEmpty && mood == nil && foodNoise == nil && energy == nil && sleepQuality == nil
            && [sleepHours, exercise, steps, restingHr, activeCalories, notes].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Fill in the day's saved check-in: always for a new day, and for the same day only if it
    /// wasn't loaded yet and nothing has been typed (so a refresh never wipes typing).
    private func load(force: Bool) {
        let cur = store.dashboard?.checkins.first { $0.day == day }
        if !force && loadedDay == day && (loadedRow || cur == nil || !isBlank) { return }
        ate = cur?.ateVsUsual ?? ""
        moved = cur?.movedVsUsual ?? ""
        feel = cur?.doseFeel ?? ""
        mood = cur?.mood.map { Int($0) }
        foodNoise = cur?.foodNoise.map { Int($0) }
        energy = cur?.energy.map { Int($0) }
        sleepQuality = cur?.sleepQuality.map { Int($0) }
        sleepHours = MLNum.plain(cur?.sleepHours)
        exercise = MLNum.plain(cur?.exerciseMinutes)
        steps = MLNum.plain(cur?.steps)
        restingHr = MLNum.plain(cur?.restingHr)
        activeCalories = MLNum.plain(cur?.activeCalories)
        notes = cur?.notes ?? ""
        loadedDay = day
        loadedRow = cur != nil
        if force { message = nil }
    }

    // MARK: Saving

    private func save() {
        guard !busy else { return }
        var payload: [String: Any] = ["day": day]
        if !ate.isEmpty { payload["ate_vs_usual"] = ate }
        if !moved.isEmpty { payload["moved_vs_usual"] = moved }
        if !feel.isEmpty { payload["dose_feel"] = feel }
        let ints: [(String, Int?)] = [
            ("mood", mood), ("food_noise", foodNoise), ("energy", energy), ("sleep_quality", sleepQuality),
            ("exercise_minutes", MLNum.int(exercise)), ("steps", MLNum.int(steps)),
            ("resting_hr", MLNum.int(restingHr)), ("active_calories", MLNum.int(activeCalories)),
        ]
        for (key, value) in ints {
            if let v = value { payload[key] = v }
        }
        if let sh = MLNum.double(sleepHours) { payload["sleep_hours"] = sh }
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { payload["notes"] = n }
        if payload.count == 1 {
            withAnimation { message = MLMessage(ok: false, text: "Answer at least one question first.") }
            return
        }
        let success = day == LogTime.today() ? "Saved today’s check-in." : "Saved the check-in for \(MLFmt.shortKey(day))."
        busy = true
        message = nil
        Task {
            let m = await MLWrite.send(store, "checkin_upsert", payload, success: success)
            busy = false
            withAnimation { message = m }
            if m.ok {
                loadedRow = true
                onSaved?()
            }
        }
    }
}

/// A Done button over the number pads when the screen around the form doesn't have one.
struct MLCheckinKeyboardDone: ViewModifier {
    let needed: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if needed {
            content.toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { MLKeyboard.dismiss() }
                }
            }
        } else {
            content
        }
    }
}
