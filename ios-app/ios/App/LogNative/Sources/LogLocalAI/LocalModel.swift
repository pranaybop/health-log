import Foundation
import Observation
import UIKit
import os
import LogCore
import MLX
import MLXLLM
import MLXLMCommon
import HuggingFace
import Tokenizers

// Ask with an open model that runs on the phone (MLX on the iPhone's GPU). The model is
// downloaded once from Hugging Face into Application Support/Models, then everything runs
// offline: the question and the log never leave the phone.
//
// Models are the ones the Locally AI app lists that MLX Swift can load as-is:
//   Bonsai 2 (PrismML, ternary weights, Qwen 3.5 based)  `prism_hadamard_qwen35`
//   Qwen 3.5 (Alibaba)                                    `qwen3_5`

public struct LocalModelChoice: Identifiable, Hashable, Sendable {
    public var id: String          // Hugging Face repo
    public var name: String
    public var detail: String
    /// Download size, GB.
    public var sizeGB: Double
    /// Rough memory needed while answering, GB (weights plus working room).
    public var needsGB: Double

    public static let bonsai9B = LocalModelChoice(
        id: "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit", name: "Bonsai 2 9B",
        detail: "PrismML. The sharpest model that fits an 8 GB iPhone, but about half the speed of the 4B.",
        sizeGB: 3.6, needsGB: 4.3)
    public static let bonsai4B = LocalModelChoice(
        id: "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", name: "Bonsai 2 4B",
        detail: "PrismML. Quick answers on an iPhone 15 Pro; the best balance of speed and quality.",
        sizeGB: 1.9, needsGB: 2.5)
    public static let qwen4B = LocalModelChoice(
        id: "mlx-community/Qwen3.5-4B-4bit", name: "Qwen 3.5 4B",
        detail: "Alibaba. A well-known all-rounder at 4-bit.",
        sizeGB: 3.1, needsGB: 3.8)

    public static let all: [LocalModelChoice] = [bonsai9B, bonsai4B, qwen4B]

    /// Bonsai 2 4B: on an iPhone 15 Pro the 9B fits but answers about half as fast.
    public static var recommended: LocalModelChoice { bonsai4B }

    public static func named(_ id: String?) -> LocalModelChoice? { all.first { $0.id == id } }

    public var sizeText: String { String(format: "%.1f GB", sizeGB) }
}

@MainActor
@Observable
public final class LocalModel {
    public static let shared = LocalModel()

    public enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// The repo whose weights are loaded right now.
    public private(set) var loadedID: String?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?
    /// A session that has already read the instructions and tools; new conversations fork it so
    /// they don't read them again. Keyed by model and instructions.
    @ObservationIgnored private var base: (key: String, session: ChatSession)?
    @ObservationIgnored private var warming: Task<Void, Never>?
    /// The answer being written, and the conversation writing it.
    @ObservationIgnored private var generation: Task<Void, Error>?
    @ObservationIgnored private var generatingIn: ChatSession?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    private init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        }
        // iOS ends an app that sends GPU work once it's in the background, so stop the model as
        // soon as the app starts to leave the screen (willResignActive comes before that).
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopGPU() }
        }
    }

    /// Cancels the answer, the warm-up and any load in progress, then waits for the GPU to finish
    /// what it already has (a background task keeps the app awake for that).
    public func stopGPU() {
        let sessions = [generatingIn, base?.session].compactMap { $0 }
        let running = generation != nil || warming != nil || task != nil
        guard running else { return }
        generation?.cancel()
        warming?.cancel()
        task?.cancel()
        let bg = UIApplication.shared.beginBackgroundTask(withName: "Stop the local model", expirationHandler: nil)
        Task { @MainActor in
            for s in sessions { await s.synchronize() }
            MLX.Memory.clearCache()
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
    }

    /// Low on memory: stop first (freeing weights the GPU is still using would crash), then unload.
    private func memoryWarning() {
        let sessions = [generatingIn, base?.session].compactMap { $0 }
        generation?.cancel()
        warming?.cancel()
        Task { @MainActor in
            for s in sessions { await s.synchronize() }
            self.unload()
        }
    }

    // MARK: Files

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    /// The Hugging Face cache layout: Models/models--org--name.
    static func folder(_ c: LocalModelChoice) -> URL {
        root.appendingPathComponent("models--" + c.id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    private static func doneKey(_ c: LocalModelChoice) -> String { "log.localModel.done." + c.id }

    /// Downloaded completely (and still on disk).
    public func isDownloaded(_ c: LocalModelChoice) -> Bool {
        UserDefaults.standard.bool(forKey: Self.doneKey(c)) && FileManager.default.fileExists(atPath: Self.folder(c).path)
    }

    public var downloaded: [LocalModelChoice] { LocalModelChoice.all.filter(isDownloaded) }

    public func delete(_ c: LocalModelChoice) {
        if loadedID == c.id { unload() }
        if case .downloading = state { task?.cancel() }
        try? FileManager.default.removeItem(at: Self.folder(c))
        UserDefaults.standard.removeObject(forKey: Self.doneKey(c))
        state = .idle
    }

    public func unload() {
        warming?.cancel()
        warming = nil
        base = nil
        container = nil
        loadedID = nil
        if state == .ready { state = .idle }
        MLX.Memory.clearCache()
    }

    // MARK: Download and load

    /// Free memory this app could still use, GB (nil where the system doesn't say).
    public static var availableGB: Double? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Double(bytes) / 1_000_000_000 : nil
    }

    /// Download if needed, then load into memory. Safe to call again; it returns once ready.
    public func prepare(_ c: LocalModelChoice) async {
        if loadedID == c.id, container != nil { state = .ready; return }
        if let t = task { await t.value; if loadedID == c.id { return } }
        let t = Task { await self.load(c) }
        task = t
        await t.value
        task = nil
    }

    private func load(_ c: LocalModelChoice) async {
        unload()
        if isDownloaded(c), let free = Self.availableGB, free < c.needsGB {
            state = .failed("\(c.name) needs about \(String(format: "%.1f", c.needsGB)) GB free and there's \(String(format: "%.1f", free)) GB right now. Close other apps and try again, or pick \(LocalModelChoice.bonsai4B.name).")
            return
        }
        state = isDownloaded(c) ? .loading : .downloading(0)
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var rootURL = Self.root
            try? rootURL.setResourceValues(excluded)

            let configuration = ModelConfiguration(id: c.id, extraEOSTokens: ["<|im_end|>"])
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: HubModelDownloader(cache: Self.root),
                using: HubTokenizerLoader(),
                configuration: configuration,
                progress: .download { p in
                    let f = p.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = LocalModel.shared.state {
                            LocalModel.shared.state = f >= 0.999 ? .loading : .downloading(f)
                        }
                    }
                })
            try Task.checkCancellation()
            UserDefaults.standard.set(true, forKey: Self.doneKey(c))
            container = loaded
            loadedID = c.id
            state = .ready
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(Self.describe(error, c))
        }
    }

    static func describe(_ error: Error, _ c: LocalModelChoice) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Couldn’t download \(c.name). Check your connection (Wi-Fi is best for \(c.sizeText)) and try again; it picks up where it stopped."
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "Not enough storage for \(c.name) (\(c.sizeText))."
        }
        return "\(c.name) couldn’t start: \(error.localizedDescription)"
    }

    // MARK: Chat

    static var parameters: GenerateParameters {
        var p = GenerateParameters()
        p.maxTokens = 600
        p.temperature = 0.7
        p.topP = 0.8
        p.topK = 20
        p.presencePenalty = 1.5
        // Read the prompt in smaller pieces: a lower memory peak on the phone.
        p.prefill.stepSize = 256
        return p
    }

    private func key(_ instructions: String) -> String { "\(loadedID ?? "")|\(instructions.hashValue)" }

    private func makeSession(_ container: ModelContainer, instructions: String, dashboard: Dashboard?) -> ChatSession {
        var tools: [ToolSpec]?
        var dispatch: (@Sendable (ToolCall) async throws -> String)?
        if let d = dashboard {
            tools = AskTools.functionSchemas
            dispatch = { call in
                AskTools.run(call.function.name, arguments: call.function.arguments.mapValues { $0.anyValue }, d: d)
            }
        }
        return ChatSession(container, instructions: instructions, generateParameters: Self.parameters,
                           additionalContext: ["enable_thinking": false], tools: tools, toolDispatch: dispatch)
    }

    /// Reads the instructions (and tools) once in the background, so the first question only
    /// has to read itself. Call when Ask opens; it's a no-op if already done for these instructions.
    public func warm(instructions: String, dashboard: Dashboard?) {
        guard let container, base?.key != key(instructions), warming == nil else { return }
        let session = makeSession(container, instructions: instructions, dashboard: dashboard)
        base = (key(instructions), session)
        warming = Task { @MainActor in
            var quick = Self.parameters
            quick.maxTokens = 1
            session.generateParameters = quick
            _ = try? await session.respond(to: "Ready?")
            session.generateParameters = Self.parameters
            self.warming = nil
        }
    }

    /// Writes the answer to `question`, calling `onText` with the raw text so far. Returns false
    /// when it stopped early (the app left the screen, or memory ran low); what was written stays.
    public func answer(_ chat: LocalChat, _ question: String, onText: @escaping @MainActor (String) -> Void) async throws -> Bool {
        if let w = warming { await w.value }
        let session = chat.session
        let t = Task { @MainActor in
            var raw = ""
            for try await chunk in session.streamResponse(to: question) {
                try Task.checkCancellation()
                raw += chunk
                onText(raw)
            }
        }
        generation = t
        generatingIn = session
        defer {
            if generatingIn === session { generation = nil; generatingIn = nil }
        }
        do {
            try await t.value
            return !t.isCancelled
        } catch is CancellationError {
            await session.synchronize()
            return false
        } catch {
            if t.isCancelled { await session.synchronize(); return false }
            throw error
        }
    }

    /// A conversation with the loaded model. Thinking is off, with the sampler PrismML and Qwen
    /// recommend for non-thinking chat. With a dashboard, the model can call AskTools.
    public func newChat(instructions: String, dashboard: Dashboard? = nil) async -> LocalChat? {
        guard let container else { return nil }
        if let w = warming { await w.value }
        if let b = base, b.key == key(instructions) {
            // Keeps the cached instructions and tools; the warm-up turn is dropped.
            let fork = await b.session.fork(history: [])
            fork.generateParameters = Self.parameters
            return LocalChat(session: fork, modelID: loadedID ?? "")
        }
        // Not warmed: this conversation reads the instructions, and later ones fork from it.
        let session = makeSession(container, instructions: instructions, dashboard: dashboard)
        base = (key(instructions), session)
        return LocalChat(session: session, modelID: loadedID ?? "")
    }
}

/// One conversation; keeps the model's context between questions.
@MainActor
public final class LocalChat {
    let session: ChatSession
    public let modelID: String

    init(session: ChatSession, modelID: String) {
        self.session = session
        self.modelID = modelID
    }

    public func ask(_ question: String) async throws -> String {
        let raw = try await session.respond(to: question)
        return Self.clean(raw)
    }

    /// The answer as it's written, chunk by chunk (raw; pass the running text through `clean`).
    public func stream(_ question: String) -> AsyncThrowingStream<String, Error> {
        session.streamResponse(to: question)
    }

    /// Drops any <think>…</think> block the model wrote anyway.
    nonisolated public static func clean(_ text: String) -> String {
        var t = text
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) {
                t.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                t.removeSubrange(open.lowerBound..<t.endIndex)
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Hugging Face adapters (what MLXHuggingFace's macros would generate)

struct HubModelDownloader: MLXLMCommon.Downloader {
    let cache: URL

    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        guard let repo = HuggingFace.Repo.ID(rawValue: id) else {
            throw NSError(domain: "LogLocalAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad model name \(id)."])
        }
        let client = HubClient(cache: HubCache(cacheDirectory: cache))
        return try await client.downloadSnapshot(
            of: repo, revision: revision ?? "main", matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) })
    }
}

struct HubTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
