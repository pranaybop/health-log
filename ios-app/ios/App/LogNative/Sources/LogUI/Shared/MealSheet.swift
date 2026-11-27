import SwiftUI
import LogCore

/// "Log a meal" in the app: describe it, let your AI estimate it (optional), check every number,
/// then save. Items can also be typed in by hand.
struct MealSheet: View {
    @Environment(LogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var items: [MealItem] = []
    @State private var mealType: String?
    @State private var eatenAt = Date()
    @State private var usedAI = false
    @State private var busy = false
    @State private var message: String?
    @State private var config = MealAIConfig.load()
    @FocusState private var describing: Bool

    private static let types = ["breakfast", "lunch", "dinner", "snack"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What did you eat?", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($describing)
                    if let config {
                        Button(action: estimate) {
                            Label(busy ? "Estimating…" : "Estimate with \(config.provider.name)", systemImage: "sparkles")
                        }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Text("Add an AI key in Account to estimate meals from a description. You can still add items by hand.")
                            .font(.footnote).foregroundStyle(LogColor.ink2)
                    }
                } footer: {
                    if config != nil { Text("The description goes to \(config!.provider.name) with your key. Nothing is saved until you tap Save.") }
                }

                if !items.isEmpty {
                    Section("Items") {
                        ForEach($items) { $it in ItemRow(item: $it) }
                            .onDelete { items.remove(atOffsets: $0) }
                    }
                    Section {
                        HStack {
                            Text("Total").font(.headline)
                            Spacer()
                            Text("\(Fmt.num(total(\.calories), 0)) cal · \(Fmt.num(total(\.proteinG), 0)) g protein")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }

                Section {
                    Button { items.append(MealItem(item: "")) } label: { Label("Add an item by hand", systemImage: "plus") }
                    Picker("Meal", selection: $mealType) {
                        Text("Not set").tag(String?.none)
                        ForEach(Self.types, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                    }
                    DatePicker("Eaten", selection: $eatenAt, in: Date().addingTimeInterval(-6 * 86400)...Date())
                }

                if let message {
                    Section { Text(message).foregroundStyle(LogColor.critInk) }
                }
            }
            .navigationTitle("Log a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(busy || !canSave)
                }
            }
            .onAppear { describing = true }
        }
    }

    private var canSave: Bool {
        !items.isEmpty && items.allSatisfy { !$0.item.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func total(_ key: KeyPath<MealItem, Double?>) -> Double {
        items.reduce(0) { $0 + ($1[keyPath: key] ?? 0) }
    }

    private func estimate() {
        guard let config else { return }
        busy = true
        message = nil
        describing = false
        Task {
            defer { busy = false }
            do {
                let e = try await MealAI.estimate(text, config: config)
                items = e.items
                if mealType == nil { mealType = e.mealType ?? Self.guessType(eatenAt) }
                usedAI = true
            } catch {
                message = (error as? LogError)?.message ?? "Couldn’t estimate that."
            }
        }
    }

    private func save() {
        busy = true
        message = nil
        let clean = items.map { var i = $0; i.item = i.item.trimmingCharacters(in: .whitespaces); return i }
        Task {
            defer { busy = false }
            do {
                let r = try await store.write("meal_log", MealAI.payload(clean, mealType: mealType ?? Self.guessType(eatenAt), eatenAt: eatenAt, usedAI: usedAI))
                if (r["ok"] as? Bool) == false {
                    message = "Couldn’t save (\((r["error"] as? String) ?? "error"))."
                } else {
                    dismiss()
                }
            } catch {
                message = (error as? LogError)?.message ?? "Couldn’t save."
            }
        }
    }

    static func guessType(_ d: Date) -> String {
        switch LogTime.hour(d) {
        case 4..<11: return "breakfast"
        case 11..<15: return "lunch"
        case 17..<22: return "dinner"
        default: return "snack"
        }
    }
}

private struct ItemRow: View {
    @Binding var item: MealItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Food", text: $item.item).font(.headline)
            TextField("Amount", text: Binding(get: { item.quantity ?? "" }, set: { item.quantity = $0.isEmpty ? nil : $0 }))
                .font(.subheadline).foregroundStyle(LogColor.ink2)
            HStack(spacing: 10) {
                num("Cal", \.calories)
                num("Protein g", \.proteinG)
                num("Carbs g", \.carbsG)
                num("Fat g", \.fatG)
            }
        }
        .padding(.vertical, 4)
    }

    private func num(_ label: String, _ key: WritableKeyPath<MealItem, Double?>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(LogColor.ink2)
            TextField("0", value: Binding(get: { item[keyPath: key] }, set: { item[keyPath: key] = $0 }),
                      format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .font(.subheadline.monospacedDigit())
        }
    }
}
