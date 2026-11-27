import SwiftUI
import LogCore

/// Where the calories came from (CalorieBreakdown): one stacked bar of protein, carbs and fat by
/// energy with each one's share and grams, then each meal's share of the day, then protein
/// density against what the targets need. Used on Today (one day) and Trends › Food (30-day average).
struct CalorieBreakdownView: View {
    let b: CalorieBreakdown
    /// Protein per 100 kcal the targets ask for.
    var targetDensity: Double?
    /// "a day" for averages.
    var perDay: Bool = false

    static func color(_ id: String) -> Color {
        switch id {
        case "protein": return LogColor.s2
        case "carbs": return LogColor.s3
        case "fat": return LogColor.s4
        default: return LogColor.axis
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where the calories came from").font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink)
                StackedBar(parts: b.macros.map { ($0.id, $0.share) })
                    .frame(height: 14)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    ForEach(b.macros) { m in macroRow(m) }
                }
            }
            if b.meals.count > 1 || (b.meals.first.map { $0.count > 1 } ?? false) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(perDay ? "By meal, an average day" : "By meal").font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink)
                    ForEach(b.meals) { m in mealRow(m) }
                }
            }
            if let line = densityLine {
                Text(line.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(line.good ? LogColor.goodInk : LogColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func macroRow(_ m: CalorieBreakdown.Macro) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Self.color(m.id)).frame(width: 10, height: 10)
            Text(m.label).font(.subheadline).foregroundStyle(LogColor.ink)
            Spacer(minLength: 6)
            Text(m.grams.map { "\(Fmt.num($0, 0)) g" } ?? "\(Fmt.num(m.kcal, 0)) kcal")
                .font(.subheadline).monospacedDigit().foregroundStyle(LogColor.ink2)
            Text("\(Fmt.num(m.share * 100, 0))%")
                .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(LogColor.ink)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(m.label)
        .accessibilityValue("\(Fmt.num(m.share * 100, 0)) percent of calories\(m.grams.map { ", \(Fmt.num($0, 0)) grams" } ?? "")")
    }

    private func mealRow(_ m: CalorieBreakdown.MealPart) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.label).font(.subheadline).foregroundStyle(LogColor.ink)
                Spacer(minLength: 6)
                Text("\(Fmt.num(m.kcal, 0)) kcal · \(Fmt.num(m.protein, 0)) g protein")
                    .font(.footnote).monospacedDigit().foregroundStyle(LogColor.ink2)
                Text("\(Fmt.num(m.share * 100, 0))%")
                    .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(LogColor.ink)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            ShareBar(share: m.share, color: LogColor.s1, height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    private var densityLine: (text: String, good: Bool)? {
        guard let d = b.proteinPer100, b.macros.first(where: { $0.id == "protein" })?.grams != nil else { return nil }
        var text = "\(Fmt.num(d, 1)) g protein per 100 kcal"
        var good = false
        if let t = targetDensity {
            good = d >= t - 0.05
            text += good ? ", on track for your targets (\(Fmt.num(t, 1)))." : "; your targets need \(Fmt.num(t, 1)). Leaner protein closes the gap."
        } else {
            text += "."
        }
        if let f = b.fiber, f > 0 { text += " Fiber \(Fmt.num(f, 0)) g\(perDay ? " a day" : "")." }
        return (text, good)
    }
}

/// Segments side by side, each as wide as its share, with hairline gaps.
private struct StackedBar: View {
    let parts: [(id: String, share: Double)]

    var body: some View {
        GeometryReader { g in
            let shown = parts.filter { $0.share > 0.001 }
            let gap: CGFloat = 2
            let width = max(0, g.size.width - gap * CGFloat(max(0, shown.count - 1)))
            HStack(spacing: gap) {
                ForEach(shown, id: \.id) { p in
                    Rectangle()
                        .fill(CalorieBreakdownView.color(p.id))
                        .frame(width: max(2, width * CGFloat(p.share)))
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
        }
    }
}
