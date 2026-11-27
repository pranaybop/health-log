import SwiftUI
import UIKit
import LogCore

// Building blocks for the Log tab's forms and the shared check-in form. Internal, prefixed "ML".

struct MLMessage: Equatable {
    var ok: Bool
    var text: String
}

/// A save, plus the raw log-write body (so a weigh-in can offer a photo for that row).
struct MLWriteOutcome {
    var message: MLMessage
    var body: [String: Any]
}

@MainActor
enum MLWrite {
    static func send(_ store: LogStore, _ action: String, _ payload: [String: Any], success: String) async -> MLMessage {
        await sendDetailed(store, action, payload, success: success).message
    }

    static func sendDetailed(_ store: LogStore, _ action: String, _ payload: [String: Any], success: String) async -> MLWriteOutcome {
        let outcome: MLWriteOutcome
        do {
            let r = try await store.write(action, payload)
            if r.isEmpty {
                outcome = MLWriteOutcome(message: MLMessage(ok: false, text: "Could not save: write_failed"), body: r)
            } else if let ok = r["ok"] as? Bool, ok == false {
                let err = (r["error"] as? String) ?? "write_failed"
                let field = (r["field"] as? String).map { " (\($0))" } ?? ""
                outcome = MLWriteOutcome(message: MLMessage(ok: false, text: "Could not save: \(err)\(field)"), body: r)
            } else {
                outcome = MLWriteOutcome(message: MLMessage(ok: true, text: success), body: r)
            }
        } catch let e as LogError {
            let text = e == .unauthorized
                ? "Passcode was rejected. Lock and unlock again."
                : "Could not save: \(e.message)"
            outcome = MLWriteOutcome(message: MLMessage(ok: false, text: text), body: [:])
        } catch {
            outcome = MLWriteOutcome(message: MLMessage(ok: false, text: "Could not save: \(error.localizedDescription)"), body: [:])
        }
        let msg = outcome.message
        UIAccessibility.post(notification: .announcement, argument: msg.text)
        if msg.ok {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        return outcome
    }
}

enum MLNum {
    static func text(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return "" }
        return t
    }
    static func double(_ s: String) -> Double? {
        let t = text(s)
        return t.isEmpty ? nil : Double(t)
    }
    /// parseInt: the whole-number part.
    static func int(_ s: String) -> Int? {
        guard let v = double(s), abs(v) < 1e15 else { return nil }
        return Int(v.rounded(.towardZero))
    }
    /// A stored value back into an input: 7 -> "7", 7.5 -> "7.5".
    static func plain(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        if v.rounded() == v && abs(v) < 1e15 { return String(Int(v)) }
        return String(v)
    }
}

enum MLKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct MLKeyboardDoneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a screen that already puts a Done button over the keyboard.
    var mlKeyboardDoneShown: Bool {
        get { self[MLKeyboardDoneKey.self] }
        set { self[MLKeyboardDoneKey.self] = newValue }
    }
}

struct MLField<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(LogColor.ink2)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The filled input look.
struct MLInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A text or number input with a label.
struct MLInput: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default
    var maxLength: Int? = nil
    var big = false

    var body: some View {
        MLField(label) {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .font(big ? .logNumber(28, weight: .semibold) : .body)
                .foregroundStyle(LogColor.ink)
                .autocorrectionDisabled(keyboard != .default)
                .submitLabel(.done)
                .modifier(MLInputStyle())
                .onChange(of: text) { _, new in
                    if let m = maxLength, new.count > m { text = String(new.prefix(m)) }
                }
                .accessibilityLabel(label)
        }
    }
}

struct MLOption: Hashable {
    let value: String
    let label: String
}

struct MLChips: View {
    let options: [MLOption]
    @Binding var value: String
    var grid = false

    var body: some View {
        if grid {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(options, id: \.self) { o in chip(o, radius: 12, fill: LogColor.surface2) }
            }
        } else {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { o in chip(o, radius: 9, fill: Color.clear) }
            }
            .padding(3)
            .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func chip(_ o: MLOption, radius: CGFloat, fill: Color) -> some View {
        let on = value == o.value
        return Button {
            value = o.value
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(o.label)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .foregroundStyle(on ? Color.white : LogColor.ink)
                .frame(maxWidth: .infinity, minHeight: 36)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(on ? LogColor.accent : fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct MLScale: View {
    let label: String
    @Binding var value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(LogColor.ink2)
                Spacer()
                Text(value.map { String($0) } ?? "—")
                    .font(.logNumber(17))
                    .foregroundStyle(value == nil ? LogColor.ink2 : LogColor.ink)
            }
            Slider(value: Binding<Double>(get: { Double(value ?? 6) }, set: { value = Int($0.rounded()) }), in: 1...10, step: 1)
                .tint(value == nil ? LogColor.axis : LogColor.accent)
                .accessibilityLabel(label)
                .accessibilityValue(value.map { "\($0) out of 10" } ?? "Not set")
        }
    }
}

/// The save button: full width, disabled while saving.
struct MLSaveButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(LogColor.accent)
        .disabled(busy)
    }
}

struct MLMessageView: View {
    let message: MLMessage?
    var body: some View {
        if let m = message {
            Text(m.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(m.ok ? LogColor.goodInk : LogColor.critInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(m.ok ? LogColor.goodSoft : LogColor.critSoft, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

struct MLFold<Content: View>: View {
    let title: String
    let hint: String?
    @Binding var open: Bool
    let content: Content

    init(_ title: String, hint: String?, open: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self._open = open
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(LogColor.ink)
                        if let hint { Text(hint).font(.footnote).foregroundStyle(LogColor.ink2).multilineTextAlignment(.leading) }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LogColor.ink2)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LogMetric.cardPad)
        .background(LogColor.surface, in: RoundedRectangle(cornerRadius: LogMetric.cardRadius, style: .continuous))
    }
}

/// Clears a success message after a few seconds (errors stay until the next save).
struct MLAutoClear: ViewModifier {
    @Binding var message: MLMessage?
    func body(content: Content) -> some View {
        content.task(id: message) {
            guard let m = message, m.ok, !MLDebug.flag("-sampleMessages"), !MLDebug.flag("-samplePhoto") else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if message == m { withAnimation { message = nil } }
        }
    }
}
