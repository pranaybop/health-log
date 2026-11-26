import SwiftUI
import LogCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Trends → Ask: chat with your own log, answered right here in the app.
///
/// - On this iPhone: Apple Intelligence's on-device model. Free, no key, nothing leaves the phone.
///   Needs an Apple Intelligence iPhone on iOS 26 with Apple Intelligence turned on. Its context
///   is small, so it sees the last two weeks.
/// - Claude or Grok: the person's own API key (kept in the Keychain), called straight from the
///   phone. Sees about 90 days. A Claude or SuperGrok subscription doesn't include API access,
///   so this needs a key from the provider's developer console.
struct AskSectionView: View {
    var dashboard: Dashboard

    @AppStorage("log.askProvider") var providerID: String = ""
    @AppStorage("log.askModel.claude") var claudeModel: String = AskProvider.claude.defaultModel
    @AppStorage("log.askModel.grok") var grokModel: String = AskProvider.grok.defaultModel
    @State var turns: [AskTurn] = []
    @State var draft = ""
    @State var busy = false
    @State var error: String?
    @State var keyDraft = ""
    @State var hasKey: [AskProvider: Bool] = [:]
    @State var showSettings = false
    /// The on-device session (a LanguageModelSession on iOS 26), kept so follow-ups have context.
    @State var localSession: AnyObject?
    @FocusState var inputFocused: Bool

    static let suggestions = [
        "How is my weight trending this month?",
        "Which days did I hit my protein target?",
        "Does my sleep change after a shot?",
        "What’s different about my best weeks?",
        "How many steps do I average on workout days?",
    ]

    var provider: AskProvider {
        if let p = AskProvider(rawValue: providerID) { return p }
        if OnDevice.unavailableReason == nil { return .onDevice }
        if AskKeyStore.read(.claude) != nil { return .claude }
        if AskKeyStore.read(.grok) != nil { return .grok }
        return .onDevice
    }

    var model: String {
        switch provider {
        case .claude: return claudeModel.isEmpty ? AskProvider.claude.defaultModel : claudeModel
        case .grok: return grokModel.isEmpty ? AskProvider.grok.defaultModel : grokModel
        case .onDevice: return ""
        }
    }

    /// Why this provider can't answer yet, or nil when it can.
    var blocker: String? {
        switch provider {
        case .onDevice: return OnDevice.unavailableReason
        case .claude, .grok: return (hasKey[provider] ?? false) ? nil : "Add your \(provider.label) API key under Settings to ask with \(provider.label)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            LogCard("Ask your data", accessory: {
                Button { withAnimation { showSettings.toggle() } } label: {
                    Image(systemName: "gearshape").font(.body.weight(.semibold))
                }
                .tint(LogColor.link)
                .accessibilityLabel("Ask settings")
            }) {
                Picker("Answered by", selection: Binding(get: { provider.rawValue }, set: { switchTo($0) })) {
                    ForEach(AskProvider.allCases) { p in Text(p.label).tag(p.rawValue) }
                }
                .pickerStyle(.segmented)

                if showSettings || (blocker != nil && provider != .onDevice) { settings }
                if let blocker { Caption(blocker) }

                if turns.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.suggestions, id: \.self) { q in
                            Button { ask(q) } label: {
                                Text(q)
                                    .font(.subheadline)
                                    .foregroundStyle(LogColor.ink)
                                    .multilineTextAlignment(.leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(busy || blocker != nil)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(turns) { t in bubble(t) }
                        if busy {
                            HStack(spacing: 8) { ProgressView(); Text("Thinking…").font(.subheadline).foregroundStyle(LogColor.ink2) }
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(LogColor.critInk).fixedSize(horizontal: false, vertical: true) }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask about your weight, food, meds, sleep…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .focused($inputFocused)
                        .submitLabel(.send)
                        .onSubmit { ask(draft) }
                    Button { ask(draft) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .tint(LogColor.accent)
                    .disabled(busy || blocker != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
                if !turns.isEmpty {
                    Button("New conversation") { reset() }.font(.subheadline).tint(LogColor.link).disabled(busy)
                }
                Caption(privacyNote)
            }
            .id("ask")
        }
        .onAppear { refreshKeys() }
    }

    var privacyNote: String {
        switch provider {
        case .onDevice: return "Answered by Apple Intelligence on this iPhone from your last two weeks. Nothing leaves the phone and it costs nothing. Answers can be wrong; check the numbers it quotes."
        case .claude: return "Your question and about 90 days of your log go from this iPhone straight to Anthropic with your key, billed to your Anthropic account. Answers can be wrong; check the numbers it quotes."
        case .grok: return "Your question and about 90 days of your log go from this iPhone straight to xAI with your key, billed to your xAI account. Answers can be wrong; check the numbers it quotes."
        }
    }

    @ViewBuilder var settings: some View {
        if provider == .onDevice {
            Caption("No setup. Uses Apple Intelligence (Settings › Apple Intelligence & Siri).")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if hasKey[provider] ?? false {
                    HStack {
                        Label("Key saved on this iPhone", systemImage: "key.fill").font(.subheadline).foregroundStyle(LogColor.goodInk)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            AskKeyStore.clear(provider)
                            refreshKeys()
                        }
                        .font(.subheadline)
                    }
                } else {
                    SecureField(provider.keyHint, text: $keyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button("Save key") {
                        AskKeyStore.write(provider, keyDraft)
                        keyDraft = ""
                        refreshKeys()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LogColor.accent)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text("Model").font(.subheadline).foregroundStyle(LogColor.ink2)
                    TextField(provider.defaultModel, text: provider == .claude ? $claudeModel : $grokModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.subheadline.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                Caption("The key stays in this iPhone’s Keychain and is only sent to \(provider == .claude ? "api.anthropic.com" : "api.x.ai").")
            }
        }
    }

    func bubble(_ t: AskTurn) -> some View {
        let mine = t.role == .user
        let text = (try? AttributedString(markdown: t.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t.text)
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(mine ? Color.white : LogColor.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(mine ? LogColor.accent : LogColor.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 24) }
        }
    }

    func refreshKeys() {
        var m: [AskProvider: Bool] = [:]
        for p in [AskProvider.claude, .grok] { m[p] = AskKeyStore.read(p) != nil }
        hasKey = m
    }

    func switchTo(_ id: String) {
        guard id != provider.rawValue else { return }
        providerID = id
        keyDraft = ""
        error = nil
        reset()
    }

    func reset() {
        turns = []
        localSession = nil
        error = nil
    }

    func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy, blocker == nil else { return }
        draft = ""
        error = nil
        inputFocused = false
        turns.append(AskTurn(role: .user, text: q))
        busy = true
        let p = provider
        let history = turns
        let modelID = model
        let d = dashboard
        Task { @MainActor in
            defer { busy = false }
            do {
                let answer: String
                if p == .onDevice {
                    let r = try await OnDevice.ask(q, dashboard: d, session: localSession)
                    localSession = r.session
                    answer = r.answer
                } else {
                    guard let key = AskKeyStore.read(p) else { throw LogError.server("Add your \(p.label) API key first.") }
                    let system = DataDigest.instructions + "\n\n" + DataDigest.make(d, size: .full)
                    answer = try await AskCloud.send(p, key: key, model: modelID, system: system, turns: history)
                }
                turns.append(AskTurn(role: .assistant, text: answer))
            } catch let e as LogError {
                error = e.message
            } catch {
                self.error = OnDevice.describe(error)
            }
        }
    }
}

/// Apple Intelligence on the phone. Compiles to "not available" without the iOS 26 SDK.
enum OnDevice {
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return AppleModel.unavailableReason }
        #endif
        return "On-device answers need iOS 26 with Apple Intelligence. Pick Claude or Grok and add an API key instead."
    }

    @MainActor
    static func ask(_ q: String, dashboard: Dashboard, session: AnyObject?) async throws -> (answer: String, session: AnyObject?) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await AppleModel.ask(q, dashboard: dashboard, session: session)
        }
        #endif
        throw LogError.server(unavailableReason ?? "Not available.")
    }

    static func describe(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return "That conversation got too long for the on-device model. Tap New conversation."
            case .guardrailViolation: return "Apple Intelligence declined to answer that one. Try rephrasing."
            case .unsupportedLanguageOrLocale: return "Apple Intelligence doesn’t support this language yet."
            default: return "Apple Intelligence couldn’t answer: \(e.localizedDescription)"
            }
        }
        #endif
        return error.localizedDescription
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
enum AppleModel {
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone can’t run Apple Intelligence. Pick Claude or Grok and add an API key instead."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri to ask on this iPhone for free."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Try again in a few minutes."
        case .unavailable:
            return "Apple Intelligence isn’t available right now."
        }
    }

    @MainActor
    static func newSession(_ dashboard: Dashboard) -> LanguageModelSession {
        LanguageModelSession(instructions: DataDigest.instructions + "\n\n" + DataDigest.make(dashboard, size: .compact))
    }

    @MainActor
    static func ask(_ q: String, dashboard: Dashboard, session: AnyObject?) async throws -> (answer: String, session: AnyObject?) {
        let s = (session as? LanguageModelSession) ?? newSession(dashboard)
        do {
            return (try await s.respond(to: q).content, s)
        } catch let e as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = e else { throw e }
            // Start over with just the snapshot and this question.
            let fresh = newSession(dashboard)
            return (try await fresh.respond(to: q).content, fresh)
        }
    }
}
#endif
