import SwiftUI
import LogCore

/// Evening nudge when today's food is far under target. On a GLP-1 it's easy to eat too little,
/// and very low protein costs muscle. Shows from 7 PM when calories are under half the target or
/// protein under 60% of its target, and only once something has been logged (so an unlogged day
/// doesn't read as a fast).
enum UnderEating {
    struct Low: Equatable {
        let calories: Int
        let calorieTarget: Int?
        let protein: Int
        let proteinTarget: Int?
        let lowProteinOnly: Bool
    }

    static func check(_ d: Dashboard, now: Date) -> Low? {
        guard LogTime.hour(now) >= 19 else { return nil }
        let today = LogTime.today(now)
        guard let totals = Analytics.totals(on: today, d), (totals.mealCount ?? 1) > 0 else { return nil }
        let t = Analytics.targets(d)
        let cal = totals.calories ?? 0
        let pro = totals.proteinG ?? 0
        let lowCal = t.calories.map { cal < $0 * 0.5 } ?? (cal < 800)
        let lowPro = t.protein.map { pro < $0 * 0.6 } ?? false
        guard lowCal || lowPro else { return nil }
        return Low(calories: Int(cal.rounded()), calorieTarget: t.calories.map { Int($0.rounded()) },
                   protein: Int(pro.rounded()), proteinTarget: t.protein.map { Int($0.rounded()) }, lowProteinOnly: !lowCal)
    }
}

struct UnderEatingCard: View {
    let low: UnderEating.Low

    var body: some View {
        LogCard(low.lowProteinOnly ? "Protein is low today" : "You've eaten very little today") {
            Text(line).font(.subheadline).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
            Caption("A protein-first snack before bed (Greek yogurt, a shake, cottage cheese, eggs) helps keep muscle while you lose fat. If you can't eat because of nausea, note it as a side effect.")
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(LogColor.warn).padding(18).accessibilityHidden(true)
        }
    }

    private var line: String {
        let cal = low.calorieTarget.map { "\(low.calories) of \($0) calories" } ?? "\(low.calories) calories"
        let pro = low.proteinTarget.map { "\(low.protein) of \($0) g protein" } ?? "\(low.protein) g protein"
        return "\(cal) and \(pro) so far."
    }
}
