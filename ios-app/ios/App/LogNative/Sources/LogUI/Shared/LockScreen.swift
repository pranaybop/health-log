import SwiftUI
import LogCore

/// The native lock screen: enter the passcode once; it's checked against the log and kept in the
/// Keychain. Number pad by default, letters if the passcode has them.
public struct LockScreen: View {
    @Environment(LogStore.self) private var store
    @State private var code = ""
    @State private var letters = false
    @State private var busy = false
    @FocusState private var focused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(LogColor.accent)
                .accessibilityHidden(true)
            Text("Log").font(.logNumber(34))
            Text("Enter your passcode to open your log. It stays on this iPhone.")
                .font(.subheadline).foregroundStyle(LogColor.ink2).multilineTextAlignment(.center)
            SecureField("Passcode", text: $code)
                .keyboardType(letters ? .asciiCapable : .numberPad)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.logNumber(24, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(LogColor.surface, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(submit)
            if let msg = store.errorMessage {
                Text(msg).font(.subheadline).foregroundStyle(LogColor.critInk).multilineTextAlignment(.center)
            }
            Button(action: submit) {
                Text(busy ? "Checking…" : "Unlock").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(LogColor.accent)
            .disabled(busy || code.isEmpty)
            Button(letters ? "Use number pad" : "Use letters") {
                letters.toggle()
                focused = false
                DispatchQueue.main.async { focused = true }
            }
            .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LogColor.bg.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func submit() {
        guard !busy, !code.isEmpty else { return }
        busy = true
        Task {
            let ok = await store.unlock(code)
            busy = false
            if ok { code = "" }
        }
    }
}
