import Foundation

/// Where a day's calories came from: protein, carbs and fat by energy (4 / 4 / 9 kcal a gram),
/// anything logged without macros, and each meal's share. Also protein density (grams per
/// 100 kcal), the number that matters most when eating less on a GLP-1.
public struct CalorieBreakdown: Hashable, Sendable {
    public struct Macro: Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        /// Grams eaten (nil for "Not broken down").
        public var grams: Double?
        public var kcal: Double
        /// Share of the day's calories, 0...1.
        public var share: Double
    }

    public struct MealPart: Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var kcal: Double
        public var share: Double
        public var protein: Double
        public var count: Int
    }

    /// Calories logged (or what the macros add up to, if that's more).
    public var calories: Double
    public var macros: [Macro]
    public var meals: [MealPart]
    public var fiber: Double?
    /// Grams of protein per 100 kcal.
    public var proteinPer100: Double?
    /// Days averaged (1 for a single day).
    public var days: Int

    static let order = ["breakfast", "lunch", "dinner", "snack"]

    /// "breakfast" / "Lunch" / "snacks" -> a slot; no type -> by the hour it was eaten.
    public static func slot(_ meal: Meal) -> String {
        let t = (meal.mealType ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("breakfast") { return "breakfast" }
        if t.hasPrefix("lunch") { return "lunch" }
        if t.hasPrefix("dinner") || t.hasPrefix("supper") { return "dinner" }
        if t.hasPrefix("snack") || t == "dessert" || t == "drink" { return "snack" }
        if !t.isEmpty { return t }
        guard let at = meal.eatenDate else { return "snack" }
        let h = LogTime.calendar.component(.hour, from: at)
        switch h {
        case 4..<11: return "breakfast"
        case 11..<15: return "lunch"
        case 17..<22: return "dinner"
        default: return "snack"
        }
    }

    static func label(_ slot: String) -> String {
        switch slot {
        case "breakfast": return "Breakfast"
        case "lunch": return "Lunch"
        case "dinner": return "Dinner"
        case "snack": return "Snacks"
        default: return slot.prefix(1).uppercased() + slot.dropFirst()
        }
    }

    /// One day: macros from the day's totals (or the meals, if there are no totals).
    public static func make(meals: [Meal], totals: DailyTotal?) -> CalorieBreakdown? {
        func sum(_ k: KeyPath<Meal, Double?>) -> Double? {
            let v = meals.compactMap { $0[keyPath: k] }
            return v.isEmpty ? nil : v.reduce(0, +)
        }
        let kcal = totals?.calories ?? sum(\.calories)
        let protein = totals?.proteinG ?? sum(\.proteinG)
        let carbs = totals?.carbsG ?? sum(\.carbsG)
        let fat = totals?.fatG ?? sum(\.fatG)
        let fiber = totals?.fiberG ?? sum(\.fiberG)
        return build(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber, meals: meals, days: 1)
    }

    /// The average logged day over the last `days` days (days with nothing logged don't count).
    public static func average(_ d: Dashboard, days: Int = 30, now: Date = Date()) -> CalorieBreakdown? {
        let today = LogTime.today(now)
        let from = LogTime.shift(today, -(days - 1))
        let totals = d.dailyTotals.filter { $0.date >= from && $0.date <= today && ($0.calories ?? 0) > 0 }
        guard !totals.isEmpty else { return nil }
        let keys = Set(totals.map(\.date))
        let meals = d.meals.filter { m in m.eatenDate.map { keys.contains(LogTime.dayKey($0)) } ?? false }
        let n = Double(totals.count)
        func avg(_ k: KeyPath<DailyTotal, Double?>) -> Double? {
            let v = totals.compactMap { $0[keyPath: k] }
            return v.isEmpty ? nil : v.reduce(0, +) / n
        }
        return build(kcal: avg(\.calories), protein: avg(\.proteinG), carbs: avg(\.carbsG), fat: avg(\.fatG),
                     fiber: avg(\.fiberG), meals: meals, days: totals.count)
    }

    static func build(kcal: Double?, protein: Double?, carbs: Double?, fat: Double?, fiber: Double?,
                      meals: [Meal], days: Int) -> CalorieBreakdown? {
        let p = (protein ?? 0) * 4, c = (carbs ?? 0) * 4, f = (fat ?? 0) * 9
        let fromMacros = p + c + f
        let logged = kcal ?? 0
        let total = max(logged, fromMacros)
        guard total > 0 else { return nil }
        var macros = [
            Macro(id: "protein", label: "Protein", grams: protein, kcal: p, share: p / total),
            Macro(id: "carbs", label: "Carbs", grams: carbs, kcal: c, share: c / total),
            Macro(id: "fat", label: "Fat", grams: fat, kcal: f, share: f / total),
        ]
        // Calories logged without macros (a quick "300 kcal" entry, or estimates that don't add up).
        let rest = logged - fromMacros
        if rest > max(25, logged * 0.05) {
            macros.append(Macro(id: "other", label: "Not broken down", grams: nil, kcal: rest, share: rest / total))
        }

        var bySlot: [String: (kcal: Double, protein: Double, count: Int)] = [:]
        for m in meals {
            let s = slot(m)
            var e = bySlot[s] ?? (0, 0, 0)
            e.kcal += m.calories ?? 0
            e.protein += m.proteinG ?? 0
            e.count += 1
            bySlot[s] = e
        }
        let mealTotal = bySlot.values.reduce(0) { $0 + $1.kcal }
        let dayCount = Double(max(1, days))
        let slots = bySlot.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a < b : ia < ib
        }
        let parts = slots.compactMap { s -> MealPart? in
            guard let e = bySlot[s], e.kcal > 0 || e.count > 0 else { return nil }
            return MealPart(id: s, label: label(s), kcal: e.kcal / dayCount, share: mealTotal > 0 ? e.kcal / mealTotal : 0,
                            protein: e.protein / dayCount, count: e.count)
        }
        let density = (protein != nil && total > 0) ? (protein ?? 0) / total * 100 : nil
        return CalorieBreakdown(calories: total, macros: macros, meals: parts, fiber: fiber, proteinPer100: density, days: days)
    }

    /// Protein per 100 kcal the targets ask for (protein target ÷ calorie target × 100).
    public static func targetDensity(protein: Double?, calories: Double?) -> Double? {
        guard let protein, let calories, calories > 0 else { return nil }
        return protein / calories * 100
    }
}
