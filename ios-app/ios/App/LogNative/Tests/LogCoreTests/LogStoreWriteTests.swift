import Foundation
import XCTest
@testable import LogCore

/// Offline saves and the refresh a save asks for. The transport is a URLProtocol on `LogAPI.session`
/// so nothing here reaches the network or the Keychain.
@MainActor
final class LogStoreWriteTests: XCTestCase {
    private static var savedSession: URLSession?
    private let store = LogStore.shared

    override func setUp() async throws {
        if Self.savedSession == nil { Self.savedSession = LogAPI.session }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURL.self]
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        LogAPI.session = URLSession(configuration: config)
        ScriptedURL.reset()
        clearLogFiles()
        store.healthSync = nil
        store.isRefreshing = false
        store.refreshAgain = false
        store.credentialOverride = .passcode("test")
        store.isLocked = false
    }

    override func tearDown() async throws {
        store.healthSync = nil
        store.credentialOverride = nil
        store.refreshAgain = false
        store.isRefreshing = false
        store.isLocked = true
        ScriptedURL.reset()
        clearLogFiles()
        if let saved = Self.savedSession { LogAPI.session = saved }
    }

    /// The 201st offline save has to fail. Reporting it queued drops the log and the form says it saved.
    func testFullOfflineQueueFailsTheSave() async throws {
        ScriptedURL.failImmediately = true
        let limit = LogStore.pendingLimit
        do {
            _ = try await store.write("goal_set", ["kind": "calories", "target": 2000])
            XCTFail("goal_set is not kept offline")
        } catch let error as LogError {
            guard case .network = error else { throw error }
        }
        XCTAssertEqual(pendingFileCount(), 0)

        for n in 1...limit {
            let result = try await store.write("food_thought", ["strength": "passing"])
            XCTAssertEqual(result["ok"] as? Bool, true, "item \(n)")
            XCTAssertEqual(result["queued"] as? Bool, true, "item \(n)")
            XCTAssertEqual(store.pendingCount, n, "item \(n)")
        }
        XCTAssertEqual(pendingFileCount(), limit)

        do {
            _ = try await store.write("food_thought", ["strength": "passing"])
            XCTFail("a full queue reported the save as queued")
        } catch let error as LogError {
            guard case .network = error else { throw error }
        }
        XCTAssertEqual(store.pendingCount, limit)
        XCTAssertEqual(pendingFileCount(), limit)
    }

    /// A save while launch is still in the Apple Health sync has to show up on that refresh.
    func testSaveDuringHealthSyncRefreshShowsUp() async throws {
        let gate = Gate()
        store.healthSync = { _ in await gate.wait() }
        let refreshTask = Task { await self.store.refresh(syncHealth: true) }
        defer { gate.release() }
        guard await waitUntil({ self.store.isRefreshing }) else {
            XCTFail("refresh did not start")
            return
        }
        await gate.started()

        let writeTask = Task { try await self.store.write("measurement", ["kind": "waist", "value": 32]) }
        let writeReq = try XCTUnwrap(await ScriptedURL.next(timeout: 3))
        XCTAssertEqual(writeReq.url.lastPathComponent, "log-write")
        writeReq.finish(.success((200, Data("{\"ok\":true}".utf8))))
        let saved = try await writeTask.value
        XCTAssertEqual(saved["ok"] as? Bool, true)
        // The save's refresh is its own task. It has to run while this one is still in the sync,
        // which is the moment the old code threw that refresh away.
        let deadline = Date().addingTimeInterval(2)
        while !store.refreshAgain && Date() < deadline { await Task.yield() }
        XCTAssertTrue(store.refreshAgain)
        XCTAssertTrue(store.isRefreshing)

        gate.release()
        let first = try XCTUnwrap(await ScriptedURL.next(timeout: 3))
        XCTAssertEqual(first.url.lastPathComponent, "log-dashboard")
        first.finish(.success((200, dashboard("2026-11-28T00:00:00Z"))))

        guard let second = await ScriptedURL.next(timeout: 3) else {
            await refreshTask.value
            XCTFail("a save during refresh never showed up")
            return
        }
        XCTAssertEqual(second.url.lastPathComponent, "log-dashboard")
        second.finish(.success((200, dashboard("2026-11-28T01:00:00Z"))))
        await refreshTask.value
        XCTAssertEqual(store.dashboard?.asOf, "2026-11-28T01:00:00Z")
        XCTAssertFalse(store.isRefreshing)
    }

    /// A save while nothing is refreshing still updates the screen once.
    func testWriteWhileIdleRefreshesOnce() async throws {
        let writeTask = Task { try await self.store.write("measurement", ["kind": "waist", "value": 32]) }
        let writeReq = try XCTUnwrap(await ScriptedURL.next(timeout: 3))
        XCTAssertEqual(writeReq.url.lastPathComponent, "log-write")
        writeReq.finish(.success((200, Data("{\"ok\":true}".utf8))))
        let saved = try await writeTask.value
        XCTAssertEqual(saved["ok"] as? Bool, true)
        XCTAssertNil(saved["queued"])

        let dash = try XCTUnwrap(await ScriptedURL.next(timeout: 3))
        XCTAssertEqual(dash.url.lastPathComponent, "log-dashboard")
        dash.finish(.success((200, dashboard("2026-11-28T02:00:00Z"))))
        let showed = await waitUntil { self.store.dashboard?.asOf == "2026-11-28T02:00:00Z" && !self.store.isRefreshing }
        XCTAssertTrue(showed)

        let extra = await ScriptedURL.next(timeout: 0.2)
        extra?.finish(.success((200, dashboard("2026-11-28T03:00:00Z"))))
        XCTAssertNil(extra)
        XCTAssertEqual(store.dashboard?.asOf, "2026-11-28T02:00:00Z")
    }

    private func dashboard(_ asOf: String) -> Data {
        Data("{\"as_of\":\"\(asOf)\"}".utf8)
    }

    private func waitUntil(_ predicate: () -> Bool, seconds: Double = 2) async -> Bool {
        let steps = Int(seconds / 0.02)
        for _ in 0..<max(steps, 1) {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func pendingFileCount() -> Int {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return -1 }
        let url = root.appendingPathComponent("log", isDirectory: true).appendingPathComponent("pending.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return list.count
    }

    private func clearLogFiles() {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("log", isDirectory: true))
    }
}

/// Holds the Apple Health sync inside `refresh` until the test releases it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseCont: CheckedContinuation<Void, Never>?
    private var startedCont: CheckedContinuation<Void, Never>?
    private var started = false

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            self.releaseCont = cont
            self.started = true
            let entered = self.startedCont
            self.startedCont = nil
            self.lock.unlock()
            entered?.resume()
        }
    }

    func started() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.started {
                self.lock.unlock()
                cont.resume()
            } else {
                self.startedCont = cont
                self.lock.unlock()
            }
        }
    }

    func release() {
        self.lock.lock()
        let cont = self.releaseCont
        self.releaseCont = nil
        self.lock.unlock()
        cont?.resume()
    }
}

/// One scripted response for a `LogAPI` request, or an immediate failure.
private final class ScriptedURL: URLProtocol, @unchecked Sendable {
    struct Job {
        let url: URL
        let finish: (Result<(Int, Data), Error>) -> Void
    }

    private final class Waiter {
        let deliver: (Job) -> Void
        init(_ deliver: @escaping (Job) -> Void) { self.deliver = deliver }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    private static let lock = NSLock()
    static var failImmediately = false
    private static var pending: [Job] = []
    private static var waiters: [Waiter] = []

    static func reset() {
        lock.lock()
        failImmediately = false
        let jobs = pending
        pending = []
        waiters = []
        lock.unlock()
        for job in jobs { job.finish(.failure(URLError(.cancelled))) }
    }

    static func next(timeout: TimeInterval) async -> Job? {
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<Job?, Never>) in
            let waiter = Waiter { job in
                guard once.take() else { return }
                cont.resume(returning: job)
            }
            lock.lock()
            if pending.isEmpty {
                waiters.append(waiter)
                lock.unlock()
            } else {
                let job = pending.removeFirst()
                lock.unlock()
                if once.take() { cont.resume(returning: job) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                lock.lock()
                waiters.removeAll { $0 === waiter }
                lock.unlock()
                if once.take() { cont.resume(returning: nil) }
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let client = self.client
        let url = request.url ?? URL(string: "https://example.invalid")!
        Self.lock.lock()
        let fail = Self.failImmediately
        Self.lock.unlock()
        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let job = Job(url: url) { result in
            DispatchQueue.global(qos: .userInitiated).async {
                switch result {
                case .failure(let error):
                    client?.urlProtocol(self, didFailWithError: error)
                case .success(let (status, data)):
                    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
        Self.lock.lock()
        if Self.waiters.isEmpty {
            Self.pending.append(job)
            Self.lock.unlock()
        } else {
            let waiter = Self.waiters.removeFirst()
            Self.lock.unlock()
            waiter.deliver(job)
        }
    }

    override func stopLoading() {}
}
