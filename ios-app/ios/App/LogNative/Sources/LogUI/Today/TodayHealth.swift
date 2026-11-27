import SwiftUI
import LogCore
import LogHealth

// MARK: Sleep

/// Last night's sleep, its stages and the 7-night debt against 8-hour nights (web renderSleepNight).
struct TodaySleepCard: View {
    let m: TodayModel

    var body: some View {
        let d = m.d
        let night = Analytics.nightKey(d, view: m.key, now: m.now)
        let hours = Analytics.sleepHours(d, on: night)
        let stages = Analytics.sleepStages(d, on: night)
        let nights = LogTime.lastDays(7, now: m.now).compactMap { Analytics.sleepHours(d, on: $0) }
        if hours == nil && stages == nil && nights.count < 3 {
            if m.isToday {
                LogCard("Sleep") { EmptyNote("No sleep stages or hours yet. They appear after an Apple Health sync from the iPhone app.") }
            }
        } else {
            let avg = Analytics.mean(nights)
            let shortfall: Double? = nights.isEmpty ? nil : nights.reduce(0.0) { $0 + max(0, 8 - $1) }
            LogCard("Sleep") {
                TileGrid(tiles: [
                    TileData(label: night == m.today ? "Last night" : LogTime.shortDate(key: night), value: hours.map { "\(Fmt.num($0, 1)) h" } ?? "—",
                             detail: stageText(stages) ?? (hours != nil ? "asleep" : "no hours for this night")),
                    TileData(label: "7-night average", value: avg.map { "\(Fmt.num($0, 1)) h" } ?? "—",
                             detail: nights.isEmpty ? "needs more nights" : "\(TodayText.plural(nights.count, "night")) with data"),
                    TileData(label: "vs 8-hour nights", value: shortfall.map { "\(Fmt.num($0, 1)) h short" } ?? "—",
                             detail: "Sum of shortfalls on recorded nights, not a personal target"),
                ])
                if let stages, stages.total > 0 {
                    StageBar(stages: stages)
                    HStack(spacing: 14) {
                        legend("Core", LogColor.s1)
                        legend("Deep", LogColor.s3)
                        legend("REM", LogColor.s4)
                        legend("Awake", LogColor.axis)
                    }
                    .font(.footnote)
                    .foregroundStyle(LogColor.ink2)
                }
                if stages == nil && hours != nil {
                    TodayCaption("Stage breakdown will show once sleep stages sync from Apple Health.")
                }
                if nights.count < 3 {
                    TodayCaption("Sleep debt uses recorded nights only, compared with an 8-hour reference, and needs a few more nights to settle.")
                }
            }
        }
    }

    private func stageText(_ s: SleepStages?) -> String? {
        guard let s else { return nil }
        var bits: [String] = []
        if let v = s.core { bits.append("Core \(Fmt.num(v, 0)) min") }
        if let v = s.deep { bits.append("Deep \(Fmt.num(v, 0)) min") }
        if let v = s.rem { bits.append("REM \(Fmt.num(v, 0)) min") }
        if let v = s.awake { bits.append("Awake \(Fmt.num(v, 0)) min") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

/// Core, deep, REM and awake as shares of one bar.
private struct StageBar: View {
    let stages: SleepStages

    var body: some View {
        let parts: [(Double, Color)] = [(stages.core ?? 0, LogColor.s1), (stages.deep ?? 0, LogColor.s3), (stages.rem ?? 0, LogColor.s4), (stages.awake ?? 0, LogColor.axis)]
        let total = max(1, stages.total)
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.0 > 0 { p.1.frame(width: geo.size.width * p.0 / total) }
                }
            }
        }
        .frame(height: 14)
        .background(LogColor.surface2)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Sleep stages")
        .padding(.top, 2)
    }
}

// MARK: Body (Apple Health)

/// Steps, sleep, resting heart rate and HRV for the day, or the latest day synced (web renderSignals).
struct TodayBodyCard: View {
    let m: TodayModel

    var body: some View {
        if let h = row {
            LogCard("Body") {
                TileGrid(tiles: [
                    TileData(label: "Steps", value: h.steps.map { Fmt.num($0, 0) } ?? "—", detail: h.distanceMi.map { "\(Fmt.num($0, 1)) mi" }),
                    TileData(label: "Sleep", value: h.sleepHours.map { "\(Fmt.num($0, 1)) h" } ?? "—", detail: h.sleepHours != nil ? "asleep" : "not recorded"),
                    TileData(label: "Resting HR", value: h.restingHr.map { Fmt.num($0, 0) } ?? "—", detail: "bpm"),
                    TileData(label: "HRV", value: h.hrvMs.map { Fmt.num($0, 0) } ?? "—", detail: "ms"),
                ])
                TodayCaption(caption(h))
                if m.isToday {
                    HealthSyncPanel(compact: true)
                }
            }
        }
    }

    /// The day being viewed; for today, the latest day with steps, sleep or resting heart rate.
    private var row: DailyHealth? {
        if !m.isToday { return m.d.dailyHealth.first { $0.day == m.key } }
        return m.d.dailyHealth.last(where: { $0.steps != nil || $0.sleepHours != nil || $0.restingHr != nil })
    }

    private func caption(_ h: DailyHealth) -> String {
        if !m.isToday { return "From Apple Health." }
        if h.day == m.today { return "From Apple Health, today so far." }
        return "From Apple Health, \(LogTime.shortDate(key: h.day)). Sync to bring in newer days."
    }
}

// MARK: Macros and meals

/// Protein, carbs, fat and fiber in grams, as bars against the largest (web renderMacros).
struct TodayMacros: View {
    let totals: DailyTotal

    var body: some View {
        let rows: [(String, Double?, Bool)] = [("Protein", totals.proteinG, true), ("Carbs", totals.carbsG, false), ("Fat", totals.fatG, false), ("Fiber", totals.fiberG, false)]
        let top = max(1, rows.map { $0.1 ?? 0 }.max() ?? 1)
        VStack(spacing: 10) {
            Rectangle().fill(LogColor.hairline).frame(height: 1)
            VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 10) {
                        Text(r.0).font(.subheadline).foregroundStyle(LogColor.ink2).frame(width: 64, alignment: .leading)
                        ShareBar(share: (r.1 ?? 0) / top, color: r.2 ? LogColor.s2 : LogColor.axis)
                        Text(r.1.map { "\(Fmt.num($0, 0)) g" } ?? "—").font(.subheadline).monospacedDigit().foregroundStyle(LogColor.ink)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(r.0)
                    .accessibilityValue(r.1.map { "\(Fmt.num($0, 0)) grams" } ?? "none")
                }
            }
        }
    }
}

/// "Log a meal". Sits in the Food today card, right under today's calories. For the original log
/// it opens Log in Grok Bot (unless Account says otherwise); everyone else describes the meal in
/// the app. openURL calls UIApplication.open and says whether it was accepted, so this doesn't use
/// canOpenURL and doesn't need LSApplicationQueriesSchemes.
struct LogMealButton: View {
    @Environment(\.openURL) private var openURL
    @Environment(LogStore.self) private var store
    @State private var unavailable = false
    @State private var showSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: logMeal) {
                Label("Log a meal", systemImage: "fork.knife")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(LogColor.accent)
            .accessibilityHint(store.mealLoggingInApp ? "Describe a meal to log it" : "Opens Log in Grok Bot")
            .sheet(isPresented: $showSheet) { MealSheet().environment(store) }
            if unavailable {
                Text(LogBot.unavailableMessage)
                    .font(.footnote)
                    .foregroundStyle(LogColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Log it here instead") { showSheet = true }.font(.footnote.weight(.semibold))
            }
        }
    }

    private func logMeal() {
        if store.mealLoggingInApp { showSheet = true } else { openLogBot() }
    }

    private func openLogBot() {
        unavailable = false
        guard let url = LogBot.url else {
            unavailable = true
            return
        }
        openURL(url) { accepted in
            guard !accepted else { return }
            Task { @MainActor in unavailable = true }
        }
    }
}

/// The day's meals (web renderMeals), listed inside the Food card right under "Log a meal".
struct TodayMeals: View {
    let meals: [Meal]
    let past: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(LogColor.hairline).frame(height: 1)
            if meals.isEmpty {
                EmptyNote(past ? "No meals logged this day." : "No meals yet today.")
                    .padding(.top, 12)
            } else {
                ForEach(Array(meals.enumerated()), id: \.offset) { i, meal in
                    if i > 0 { Rectangle().fill(LogColor.hairline).frame(height: 1) }
                    row(meal)
                }
            }
        }
    }

    private func row(_ meal: Meal) -> some View {
        let sub = [TodayText.capitalize(meal.mealType ?? ""), meal.eatenDate.map(TodayText.timeCT) ?? "", meal.quantity ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meal.item ?? "—").font(.body.weight(.medium)).foregroundStyle(LogColor.ink)
                Text(sub).font(.footnote).foregroundStyle(LogColor.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(Fmt.num(meal.calories, 0)).font(.logNumber(17, weight: .semibold)).foregroundStyle(LogColor.ink)
                    Text(" kcal").font(.caption.weight(.medium)).foregroundStyle(LogColor.ink2)
                }
                Text("\(Fmt.num(meal.proteinG, 0)) g protein").font(.footnote).foregroundStyle(LogColor.ink2)
            }
            .fixedSize()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
