import SwiftUI
import LogCore

struct TodayTargets: Equatable {
    var calories: Double?
    var protein: Double?
    var isEmpty: Bool { calories == nil && protein == nil }

    static func current(_ d: Dashboard) -> TodayTargets {
        let goals = Analytics.targets(d)
        return TodayTargets(calories: goals.calories, protein: goals.protein)
    }
}

struct TodayMessage: Equatable {
    var ok: Bool
    var text: String
}

/// Food today (web renderFood): calorie and protein gauges against the targets, the targets
/// editor, the protein line and how many meals are logged.
struct TodayFoodCard: View {
    let m: TodayModel
    @Binding var editing: Bool
    @Binding var message: TodayMessage?
    let save: (_ calories: Int?, _ protein: Int?) async -> Void

    var body: some View {
        let t = m.targets
        let cal = m.totals?.calories
        let pro = m.totals?.proteinG
        if !m.isToday && m.totals == nil {
            LogCard("Food") { EmptyNote("No food logged this day.") }
        } else {
            LogCard(m.isToday ? "Food today" : "Food") {
                if m.isToday {
                    TodayLink(editing ? "Close" : (t.isEmpty ? "Set targets" : "Edit targets")) {
                        editing.toggle()
                        message = nil
                    }
                }
            } content: {
                HStack(alignment: .center, spacing: 18) {
                    FoodRing(calories: share(cal, t.calories), protein: share(pro, t.protein))
                    VStack(alignment: .leading, spacing: 12) {
                        FoodStat(label: "Calories", color: LogColor.s1, value: cal, target: t.calories, unit: "kcal", big: true,
                                 status: Self.status(kind: "calories", value: cal, target: t.calories, unit: "kcal", past: !m.isToday))
                        FoodStat(label: "Protein", color: LogColor.s2, value: pro, target: t.protein, unit: "g", big: false,
                                 status: Self.status(kind: "protein", value: pro, target: t.protein, unit: "g", past: !m.isToday))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if editing && m.isToday {
                    TargetsEditor(targets: t, save: save, cancel: { editing = false })
                }
                if let message {
                    Text(message.text).font(.subheadline.weight(.medium))
                        .foregroundStyle(message.ok ? LogColor.goodInk : LogColor.critInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if m.isToday {
                    LogMealButton()
                }
                TodayMeals(meals: m.meals, past: !m.isToday)
                if let b = CalorieBreakdown.make(meals: m.meals, totals: m.totals) {
                    Rectangle().fill(LogColor.hairline).frame(height: 1)
                    CalorieBreakdownView(b: b, targetDensity: CalorieBreakdown.targetDensity(protein: t.protein, calories: t.calories))
                }
                if m.isToday, let target = t.protein {
                    ProteinLine(s: Analytics.proteinStreak(m.d, target: target, now: m.now))
                }
                TodayCaption(caption(t))
            }
        }
    }

    private func share(_ value: Double?, _ target: Double?) -> Double {
        guard let value, let target, target > 0 else { return 0 }
        return value / target
    }

    private func caption(_ t: TodayTargets) -> String {
        let meals: String
        if let row = m.totals {
            let n = Int(row.mealCount ?? Double(m.meals.count))
            meals = "\(TodayText.plural(n, "meal")) logged"
        } else {
            meals = "Nothing logged yet today"
        }
        return t.isEmpty && !editing ? "\(meals). Set daily targets to track progress toward them." : "\(meals). Macros may be estimates."
    }

    /// "585 left", "88 g to go", "Hit, 1 g over", "699 over" (web gauge).
    static func status(kind: String, value: Double?, target: Double?, unit: String, past: Bool) -> String {
        guard let value, let target, target > 0 else { return "" }
        let diff = target - value
        if kind == "protein" {
            return diff > 0 ? "\(Fmt.num(diff, 0)) \(unit) \(past ? "short" : "to go")" : "Hit, \(Fmt.num(-diff, 0)) \(unit) over"
        }
        return diff >= 0 ? "\(Fmt.num(diff, 0)) \(past ? "under" : "left")" : "\(Fmt.num(-diff, 0)) over"
    }
}

/// Calories (outer ring) and protein (inner ring) against today's targets. Past 100% the ring
/// is full and gets a small gap at the top, like the web gauge's over-target notch.
private struct FoodRing: View {
    let calories: Double
    let protein: Double
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 112

    var body: some View {
        let side = min(size, 140)
        ZStack {
            ring(calories, color: LogColor.s1, inset: 0, width: side * 0.095)
            ring(protein, color: LogColor.s2, inset: side * 0.14, width: side * 0.08)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func ring(_ share: Double, color: Color, inset: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(LogColor.surface2, lineWidth: width)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, share)) - (share > 1 ? 0.012 : 0))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset + width / 2)
    }
}

/// One line of the food card: the colored label, amount / target, and what's left.
private struct FoodStat: View {
    let label: String
    let color: Color
    let value: Double?
    let target: Double?
    let unit: String
    let big: Bool
    let status: String

    var body: some View {
        let hasTarget = (target ?? 0) > 0
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value != nil ? Fmt.num(value, 0) : "0").font(.logNumber(big ? 28 : 22, weight: .bold)).foregroundStyle(LogColor.ink)
                Text(hasTarget ? " / \(Fmt.num(target, 0))" : " \(unit)").font(.logNumber(15, weight: .semibold)).foregroundStyle(LogColor.ink2)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if !status.isEmpty {
                Text(status).font(.footnote).foregroundStyle(LogColor.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "88 g left to hit 150 g. No hit streak yet." (web renderProteinLine)
private struct ProteinLine: View {
    let s: ProteinStreak

    var body: some View {
        let streak = s.streak == 0 ? "No hit streak yet." : "\(TodayText.plural(s.streak, "day")) in a row at your protein target."
        let remain = s.hitToday ? "Target hit today." : "\(Fmt.num(s.remaining, 0)) g left to hit \(Fmt.num(s.target, 0)) g."
        Text("\(remain) \(streak)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(s.hitToday || s.streak >= 3 ? LogColor.goodInk : LogColor.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Daily calorie and protein targets, saved with goal_set (web renderTargetsEditor).
private struct TargetsEditor: View {
    let targets: TodayTargets
    let save: (_ calories: Int?, _ protein: Int?) async -> Void
    let cancel: () -> Void

    @State private var calories = ""
    @State private var protein = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Int?

    init(targets: TodayTargets, save: @escaping (_ calories: Int?, _ protein: Int?) async -> Void, cancel: @escaping () -> Void) {
        self.targets = targets
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(LogColor.hairline).frame(height: 1).padding(.bottom, 4)
            HStack(alignment: .top, spacing: 12) {
                field("Calories (kcal)", text: $calories, prompt: "e.g. 2200", tag: 0)
                field("Protein (g)", text: $protein, prompt: "e.g. 150", tag: 1)
            }
            TodayCaption("Daily targets. Leave a box empty to keep it as it is.")
            if let error {
                Text(error).font(.subheadline.weight(.medium)).foregroundStyle(LogColor.critInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(busy ? "Saving…" : "Save targets") { submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(LogColor.accent)
                    .disabled(busy)
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .tint(LogColor.ink2)
            }
            .font(.body.weight(.semibold))
        }
        .padding(.top, 4)
        .onAppear {
            calories = targets.calories.map { Fmt.mg($0).replacingOccurrences(of: ",", with: "") } ?? ""
            protein = targets.protein.map { Fmt.mg($0).replacingOccurrences(of: ",", with: "") } ?? ""
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, tag: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(LogColor.ink2)
            TextField(prompt, text: text)
                .keyboardType(.numberPad)
                .font(.logNumber(20, weight: .semibold))
                .focused($focus, equals: tag)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }

    /// The web's checks: whole numbers, 800–6,000 kcal and 20–400 g; at least one box filled.
    private func submit() {
        let c = calories.trimmingCharacters(in: .whitespaces)
        let p = protein.trimmingCharacters(in: .whitespaces)
        if c.isEmpty && p.isEmpty { error = "Enter a calorie or protein target."; return }
        var cal: Int?
        var pro: Int?
        if !c.isEmpty {
            guard let v = Int(c), v >= 800, v <= 6000 else { error = "Calories should be a whole number from 800 to 6,000."; return }
            cal = v
        }
        if !p.isEmpty {
            guard let v = Int(p), v >= 20, v <= 400 else { error = "Protein should be a whole number from 20 to 400 g."; return }
            pro = v
        }
        error = nil
        focus = nil
        busy = true
        Task {
            await save(cal, pro)
            busy = false
        }
    }
}
