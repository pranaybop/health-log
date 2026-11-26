import SwiftUI
import LogCore
import LogHealth

/// First run for a new account: about you, your medications, Apple Health (optional; an iPhone
/// alone is enough), how to log food, and daily targets. Nothing is required except a weight.
/// Everything is saved at the end, so backing out mid-way leaves nothing half done.
public struct Onboarding: View {
    @Environment(LogStore.self) private var store
    @State private var step = 0
    @State private var name = ""
    @State private var weight = ""
    @State private var goal = ""
    @State private var feet = ""
    @State private var inches = ""
    @State private var meds: [MedDraft] = MedDraft.all
    @State private var healthAsked = false
    @State private var healthNote: String?
    @State private var provider: MealAIProvider = .openai
    @State private var apiKey = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var busy = false
    @State private var message: String?

    public init() {}

    private let steps = ["About you", "Medications", "Apple Health", "Logging food", "Daily targets"]

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LogMetric.stack) {
                    ProgressView(value: Double(step + 1), total: Double(steps.count))
                        .tint(LogColor.accent)
                        .accessibilityLabel("Step \(step + 1) of \(steps.count)")
                    Group {
                        switch step {
                        case 0: about
                        case 1: medications
                        case 2: health
                        case 3: food
                        default: targets
                        }
                    }
                    .transition(.opacity)
                    if let message {
                        Text(message).font(.subheadline).foregroundStyle(LogColor.critInk)
                    }
                }
                .padding(.horizontal, LogMetric.gutter)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LogColor.bg.ignoresSafeArea())
            .navigationTitle(steps[step])
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { withAnimation { step -= 1; message = nil } }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await store.signOut() } }.font(.subheadline)
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .disabled(busy)
        }
        .onAppear(perform: fillDefaults)
    }

    private var footer: some View {
        Button(action: next) {
            Text(busy ? "Saving…" : (step == steps.count - 1 ? "Start logging" : "Continue"))
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(LogColor.accent)
        .padding(.horizontal, LogMetric.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Steps

    private var about: some View {
        LogCard {
            Caption("This sets up your own log. Only you can see it.")
            TextField("First name (optional)", text: $name).textContentType(.givenName).modifier(FieldStyle())
            numberField("Weight today (lb)", $weight)
            numberField("Goal weight (lb, optional)", $goal)
            HStack {
                numberField("Height ft", $feet)
                numberField("in", $inches)
            }
        }
    }

    private var medications: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            Caption("Turn on what you take. You can change this later in Meds. Skip if you're not on anything yet.")
            ForEach($meds) { $m in
                LogCard {
                    Toggle(isOn: $m.on) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.headline)
                            Text(m.blurb).font(.footnote).foregroundStyle(LogColor.ink2)
                        }
                    }
                    .tint(LogColor.accent)
                    if m.on {
                        numberField("Dose (mg)", $m.dose)
                        Stepper(value: $m.everyDays, in: 1...28) {
                            Text(m.everyDays == 1 ? "Every day" : m.everyDays == 7 ? "Once a week" : "Every \(m.everyDays) days")
                        }
                        DatePicker(m.everyDays == 1 ? "Started" : "Last or first shot", selection: $m.start, displayedComponents: .date)
                    }
                }
            }
        }
    }

    private var health: some View {
        LogCard {
            Text("Bring in steps, weight, workouts and sleep.").font(.headline)
            Caption("An iPhone on its own counts steps and walking, and a smart scale adds weigh-ins. An Apple Watch adds heart rate, sleep and workouts, but you don't need one. Log works without Apple Health too.")
            if let healthNote { Text(healthNote).font(.subheadline).foregroundStyle(LogColor.ink2) }
            Button {
                Task { await connectHealth() }
            } label: {
                Label(healthAsked ? "Connected" : "Connect Apple Health", systemImage: "heart.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(LogColor.s4)
            .disabled(healthAsked)
        }
    }

    private var food: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            LogCard {
                Text("Describe a meal, review it, save it.").font(.headline)
                Caption("Type what you ate (\"two eggs, toast with butter, latte\") and an AI estimates calories and protein. You check every number before it's saved. It uses your own AI account's key, which stays on this iPhone and goes straight to that company.")
                Picker("AI", selection: $provider) {
                    ForEach(MealAIProvider.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu)
                SecureField("API key (\(provider.keyHint))", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .modifier(FieldStyle())
                Caption("No key? Skip this. You can type meals in by hand, and add a key later in Account.")
            }
        }
    }

    private var targets: some View {
        LogCard {
            Caption("A starting point you can change any time in Log.")
            numberField("Calories a day", $calories)
            numberField("Protein a day (g)", $protein)
            Caption("Protein is set from your goal weight (about 0.8 g per lb). On a GLP-1, eating enough protein helps keep muscle while you lose fat.")
        }
    }

    private func numberField(_ label: String, _ text: Binding<String>) -> some View {
        TextField(label, text: text).keyboardType(.decimalPad).modifier(FieldStyle())
    }

    // MARK: Flow

    private func fillDefaults() {
        if let p = store.dashboard?.profile {
            if name.isEmpty { name = p.displayName ?? "" }
            if goal.isEmpty, let g = p.goalWeightLb { goal = Fmt.num(g, 0) }
        }
        if let c = MealAIConfig.load() { provider = c.provider; apiKey = c.apiKey }
    }

    private func next() {
        message = nil
        if step == 0 {
            guard let w = Double(weight), (50...600).contains(w) else { message = "Enter your weight in pounds."; return }
            if !goal.isEmpty, Double(goal).map({ (50...600).contains($0) }) != true { message = "Check the goal weight."; return }
            let g = Double(goal) ?? w * 0.85
            if protein.isEmpty { protein = String(Int((g * 0.8 / 5).rounded() * 5)) }
            if calories.isEmpty { calories = "1800" }
        }
        if step == 1 {
            for m in meds where m.on {
                guard let d = Double(m.dose), (0.05...50).contains(d) else { message = "Enter a dose for \(m.name)."; return }
            }
        }
        if step == 3, !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            MealAIConfig(provider: provider, model: provider.defaultModel, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)).save()
        }
        if step < steps.count - 1 {
            withAnimation { step += 1 }
            return
        }
        Task { await finish() }
    }

    private func connectHealth() async {
        healthNote = "Asking for access…"
        let r = await NativeHealthSync.shared.syncNow(days: 30)
        healthAsked = true
        healthNote = r.error ?? (r.stored > 0 ? "Brought in \(r.stored) entries." : "Connected. New data shows up as it arrives.")
    }

    private func finish() async {
        busy = true
        defer { busy = false }
        do {
            let w = Double(weight) ?? 0
            let ft = Double(feet) ?? 0, inch = Double(inches) ?? 0
            let height = ft * 12 + inch
            var setup: [String: Any] = [
                "time_zone": TimeZone.current.identifier,
                "start_weight_lb": w,
                "settings": ["meal_logging": "app"],
            ]
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { setup["display_name"] = name.trimmingCharacters(in: .whitespaces) }
            if let g = Double(goal) { setup["goal_weight_lb"] = g }
            if (48...90).contains(height) { setup["height_in"] = height }
            try check(await store.write("account_setup", setup))
            if (store.dashboard?.weights.isEmpty ?? true) {
                try check(await store.write("weigh_in", ["weight_lb": w]))
            }
            for m in meds where m.on {
                var p: [String: Any] = ["compound": m.compound, "dose_mg": Double(m.dose) ?? 0, "every_days": m.everyDays,
                                        "start_on": LogTime.dayKey(m.start)]
                if m.compound == "tesamorelin" { p["time_of_day"] = "night" }
                try check(await store.write("regimen_set", p))
            }
            if let c = Int(calories), (800...6000).contains(c) { try check(await store.write("goal_set", ["kind": "calories", "target": c])) }
            if let pr = Int(protein), (20...400).contains(pr) { try check(await store.write("goal_set", ["kind": "protein", "target": pr])) }
            try check(await store.write("account_setup", ["done": true]))
            await store.refresh()
        } catch {
            message = (error as? LogError)?.message ?? "Couldn’t save. Try again."
        }
    }

    private func check(_ result: [String: Any]) throws {
        if (result["ok"] as? Bool) == false {
            throw LogError.server((result["error"] as? String).map { "Couldn’t save (\($0))." } ?? "Couldn’t save.")
        }
    }
}

struct MedDraft: Identifiable, Hashable {
    var id: String { compound }
    let compound: String
    let name: String
    let blurb: String
    var on = false
    var dose: String
    var everyDays: Int
    var start = Date()

    static let all: [MedDraft] = [
        MedDraft(compound: "tirzepatide", name: "Tirzepatide", blurb: "Mounjaro, Zepbound", dose: "2.5", everyDays: 7),
        MedDraft(compound: "semaglutide", name: "Semaglutide", blurb: "Ozempic, Wegovy", dose: "0.25", everyDays: 7),
        MedDraft(compound: "retatrutide", name: "Retatrutide", blurb: "Weekly", dose: "1", everyDays: 7),
        MedDraft(compound: "tesamorelin", name: "Tesamorelin", blurb: "Daily peptide, usually at night", dose: "1", everyDays: 1),
    ]
}

/// What covers the app before the tabs: sign in, then first-run setup for a new account.
public struct GateView: View {
    @Environment(LogStore.self) private var store
    public init() {}
    public var body: some View {
        if store.isLocked { LockScreen() } else { Onboarding() }
    }
}
