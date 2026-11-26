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
        detail: "PrismML. The strongest model that fits an 8 GB iPhone; answers take a little longer.",
        sizeGB: 3.6, needsGB: 4.3)
    public static let bonsai4B = LocalModelChoice(
        id: "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", name: "Bonsai 2 4B",
        detail: "PrismML. Faster and lighter, a little less sharp.",
        sizeGB: 1.9, needsGB: 2.5)
    public static let qwen4B = LocalModelChoice(
        id: "mlx-community/Qwen3.5-4B-4bit", name: "Qwen 3.5 4B",
        detail: "Alibaba. A well-known all-rounder at 4-bit.",
        sizeGB: 3.1, needsGB: 3.8)

    public static let all: [LocalModelChoice] = [bonsai9B, bonsai4B, qwen4B]

    /// Bonsai 2 9B on phones with 8 GB or more (iPhone 15 Pro and later), else Bonsai 2 4B.
    public static var recommended: LocalModelChoice {
        ProcessInfo.processInfo.physicalMemory >= 7_500_000_000 ? bonsai9B : bonsai4B
    }

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

    private init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unload() }
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

    /// A conversation with the loaded model. Thinking is off, with the sampler PrismML and Qwen
    /// recommend for non-thinking chat.
    public func newChat(instructions: String) -> LocalChat? {
        guard let container else { return nil }
        var p = GenerateParameters()
        p.maxTokens = 900
        p.temperature = 0.7
        p.topP = 0.8
        p.topK = 20
        p.presencePenalty = 1.5
        let session = ChatSession(container, instructions: instructions, generateParameters: p,
                                  additionalContext: ["enable_thinking": false])
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

    /// Drops any <think>…</think> block the model wrote anyway.
    nonisolated static func clean(_ text: String) -> String {
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
