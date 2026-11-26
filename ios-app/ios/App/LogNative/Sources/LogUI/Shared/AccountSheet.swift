import SwiftUI
import LocalAuthentication
import LogCore

/// Account: who's signed in, linking the original passcode log, how meals are logged (the Log
/// bot or in the app with your own AI key), Face ID, and signing out.
struct AccountSheet: View {
    @Environment(LogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false
    @State private var passcode = ""
    @State private var linkMessage: String?
    @State private var linking = false
    @State private var provider: MealAIProvider = .openai
    @State private var model = ""
    @State private var key = ""
    @State private var aiSaved = false
    @State private var faceID = AppLock.enabled
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Signed in") {
                    if let email = store.accountEmail {
                        LabeledContent("Account", value: email)
                    } else {
                        LabeledContent("Account", value: "Passcode only")
                        Button("Sign in with Google or email") { showSignIn = true }
                    }
                    if store.hasAccount && store.isOwner {
                        Text("This account holds your original log. The passcode still works as a backup.")
                            .font(.footnote).foregroundStyle(LogColor.ink2)
                    }
                }

                if store.hasAccount && !store.isOwner {
                    Section {
                        SecureField("Passcode", text: $passcode)
                        Button(linking ? "Linking…" : "Link the original log") { link() }
                            .disabled(linking || passcode.isEmpty)
                        if let linkMessage { Text(linkMessage).font(.footnote).foregroundStyle(LogColor.ink2) }
                    } header: {
                        Text("Have the original log's passcode?")
                    } footer: {
                        Text("Moves the passcode log into this account, once. Only for a fresh account.")
                    }
                }

                Section {
                    if store.isOwner {
                        Picker("Log a meal with", selection: Binding(get: { store.mealLoggingInApp ? "app" : "bot" }, set: setMealMode)) {
                            Text("The Log bot").tag("bot")
                            Text("This app").tag("app")
                        }
                    }
                    Picker("AI", selection: $provider) {
                        ForEach(MealAIProvider.allCases) { Text($0.name).tag($0) }
                    }
                    TextField("Model (\(provider.defaultModel))", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API key (\(provider.keyHint))", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button(aiSaved ? "Saved" : "Save key") { saveAI() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        if MealAIConfig.load() != nil {
                            Button("Remove", role: .destructive) { MealAIConfig.clear(); key = ""; aiSaved = false }
                        }
                    }
                } header: {
                    Text("Meal logging")
                } footer: {
                    Text("Your key stays in this iPhone's Keychain and goes straight to the AI company when you estimate a meal. It's never sent to the log.")
                }

                Section {
                    Toggle(AppLock.label, isOn: $faceID)
                        .tint(LogColor.accent)
                        .onChange(of: faceID) { _, on in AppLock.enabled = on }
                } footer: {
                    Text("Asks for \(AppLock.label.replacingOccurrences(of: "Require ", with: "")) when you come back to Log after a minute away.")
                }

                Section {
                    Button(store.hasAccount ? "Sign out" : "Lock", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Signing out removes your log from this iPhone. It stays safe in your account.")
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Log on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    Task { await store.signOut() }
                }
            }
            .sheet(isPresented: $showSignIn) {
                LockScreen().environment(store)
            }
            .onChange(of: store.accountEmail) { _, email in if email != nil { showSignIn = false } }
            .onAppear {
                if let c = MealAIConfig.load() { provider = c.provider; model = c.model; key = c.apiKey }
            }
        }
    }

    private func link() {
        linking = true
        linkMessage = nil
        Task {
            defer { linking = false }
            do {
                try await store.linkPasscodeLog(passcode)
                passcode = ""
                linkMessage = "Linked. Your original log is in this account now."
            } catch {
                linkMessage = (error as? LogError)?.message ?? "Couldn’t link the log."
            }
        }
    }

    private func saveAI() {
        let m = model.trimmingCharacters(in: .whitespaces)
        MealAIConfig(provider: provider, model: m.isEmpty ? provider.defaultModel : m,
                     apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines)).save()
        aiSaved = true
    }

    private func setMealMode(_ mode: String) {
        Task { _ = try? await store.write("account_setup", ["settings": ["meal_logging": mode]]) }
    }
}

/// Face ID (or the passcode) when coming back to the app. Off unless turned on in Account.
public enum AppLock {
    private static let key = "log.appLock.on"

    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var label: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Require Face ID"
        case .touchID: return "Require Touch ID"
        case .opticID: return "Require Optic ID"
        default: return "Require the iPhone passcode"
        }
    }

    /// Ask the owner of the phone. True when they passed.
    @MainActor
    public static func unlock() async -> Bool {
        let c = LAContext()
        var error: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your log")) ?? false
    }
}

/// Covers the app until Face ID passes.
public struct AppLockCover: View {
    let onUnlock: () -> Void
    @State private var failed = false

    public init(onUnlock: @escaping () -> Void) { self.onUnlock = onUnlock }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(LogColor.accent)
            Text("Log is locked").font(.title2.weight(.bold))
            Button(failed ? "Try again" : "Unlock") { Task { await attempt() } }
                .buttonStyle(.borderedProminent).tint(LogColor.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LogColor.bg.ignoresSafeArea())
        .task { await attempt() }
    }

    private func attempt() async {
        if await AppLock.unlock() { onUnlock() } else { failed = true }
    }
}
