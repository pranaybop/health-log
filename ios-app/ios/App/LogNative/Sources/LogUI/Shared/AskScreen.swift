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
/// - Your AI key: the key saved under Account (the one meal logging uses: OpenAI, Anthropic,
///   Google or xAI), called straight from the phone, with the same tools.
struct AskSectionView: View {
    var dashboard: Dashboard

    enum Mode: String, CaseIterable, Identifiable {
        case onDevice, key
        var id: String { rawValue }
        var label: String {
            switch self {
            case .onDevice: return "Apple AI"
            case .key: return "Your key"
            }
        }
    }

    @AppStorage("log.askMode") var modeID: String = ""
    @State var turns: [AskTurn] = []
    @State var draft = ""
    @State var busy = false
    @State var error: String?
    @State var config: MealAIConfig? = MealAIConfig.load()
    /// The on-device session (a LanguageModelSession on iOS 26), kept so follow-ups have context.
    @State var localSession: AnyObject?
    @FocusState var inputFocused: Bool

    static let suggestions = [
        "How is my weight trending this month?",
        "Which days did I hit my protein target?",
        "Does my readiness drop after a shot?",
        "What’s different about my best weeks?",
        "How many steps do I average on workout days?",
    ]

    var mode: Mode {
        if let m = Mode(rawValue: modeID) { return m }
        if config != nil { return .key }
        return .onDevice
    }

    /// Why this mode can't answer yet, or nil when it can.
    var blocker: String? {
        switch mode {
        case .onDevice: return OnDevice.unavailableReason
        case .key: return config == nil ? "Add an AI key under Account (the person icon › Meal logging). The same key logs meals and answers here." : nil
        }
    }

    var body: some View {
        LogCard("Ask your data") {
            Picker("Answered by", selection: Binding(get: { mode.rawValue }, set: { switchTo($0) })) {
                ForEach(Mode.allCases) { m in Text(m.label).tag(m.rawValue) }
            }
            .pickerStyle(.segmented)

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
                    ForEach(turns.filter { !$0.text.isEmpty }) { t in bubble(t) }
                    if busy && (turns.last?.role != .assistant || turns.last?.text.isEmpty == true) {
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
        .onAppear {
            config = MealAIConfig.load()
        }
    }

    var privacyNote: String {
        switch mode {
        case .onDevice:
            return "Answered by Apple Intelligence on this iPhone from your last two weeks. Nothing leaves the phone and it costs nothing. Answers can be wrong; check the numbers it quotes."
        case .key:
            let who = config?.provider.name ?? "your AI company"
            return "Your question, two weeks of your log and anything it looks up go from this iPhone straight to \(who) with your key, billed to your account there. Never through the log. Answers can be wrong; check the numbers it quotes."
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

    /// The prompt for models that can call AskTools: instructions, two weeks of overview, and
    /// a line saying to use the tools for anything else. The day only changes it once a day.
    static func toolInstructions(_ d: Dashboard) -> String {
        DataDigest.instructions + "\n" + AskTools.hint + "\n\n" + DataDigest.make(d, size: .compact)
    }

    func switchTo(_ id: String) {
        guard id != mode.rawValue else { return }
        modeID = id
        config = MealAIConfig.load()
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
        let m = mode
        let history = turns
        let cfg = config
        let d = dashboard
        Task { @MainActor in
            defer { busy = false }
            do {
                let answer: String
                if m == .onDevice {
                    let r = try await OnDevice.ask(q, dashboard: d, session: localSession)
                    localSession = r.session
                    answer = r.answer
                } else {
                    guard let cfg else { throw LogError.server("Add an AI key under Account first.") }
                    answer = try await AskCloud.send(cfg, system: Self.toolInstructions(d), turns: history, dashboard: d)
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
        return "On-device answers need iOS 26 with Apple Intelligence. Use Your AI key instead."
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
            return "This iPhone can’t run Apple Intelligence. Use Your AI key instead."
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
