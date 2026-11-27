import Foundation
import Observation

/// The app's shared state: the dashboard payload, whether you're signed in, and refresh/write.
/// Screens read `LogStore.shared` (it's also put in the SwiftUI environment).
///
/// Signed in means a session (Google or email, from log-auth) or the owner's passcode, both in the
/// Keychain. Opens instantly from the last payload saved on the phone, then refreshes. A rejected
/// sign-in signs out. Debug builds launched with `-demo <tab>` (the CI simulator check) read made-up
/// data from public/demo.json and never touch the network or the Keychain.
@MainActor
@Observable
public final class LogStore {
    public static let shared = LogStore()

    public private(set) var dashboard: Dashboard?
    /// When the shown data was produced (the payload's as_of), else when it was loaded.
    public private(set) var dataTime: Date?
    public private(set) var isRefreshing = false
    /// Showing the copy saved on the phone while a refresh runs (or after one failed).
    public private(set) var fromCache = false
    /// The last refresh failed but saved data is showing.
    public private(set) var refreshFailed = false
    public private(set) var errorMessage: String?
    public private(set) var isLocked: Bool
    /// The signed-in account's email (nil when using the passcode).
    public private(set) var accountEmail: String?
    /// This account holds the original (passcode) log, so the Grok bot logs meals for it.
    public private(set) var isOwner: Bool
    public let isDemo: Bool
    /// `-demo <tab>` and `-section <id>` launch arguments (debug builds only).
    public let demoTab: String?
    public let demoSection: String?

    /// Set by the app: run the native Apple Health sync for the last `days` days, then return.
    @ObservationIgnored public var healthSync: ((_ days: Int) async -> Void)?
    /// Set by the app: called when the app locks or unlocks.
    @ObservationIgnored public var onLockChange: ((_ locked: Bool) -> Void)?
    /// Set by the app: called after new data, so it can show or hide first-run setup.
    @ObservationIgnored public var onDataChange: (() -> Void)?

    private init() {
        var demo = false
        var tab: String?
        var section: String?
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demo") {
            demo = true
            tab = i + 1 < args.count ? args[i + 1] : "today"
        }
        if let i = args.firstIndex(of: "-section"), i + 1 < args.count { section = args[i + 1] }
        #endif
        isDemo = demo
        demoTab = tab
        demoSection = section
        let session = demo ? nil : SessionStore.read()
        isLocked = demo ? false : (session == nil && PasscodeStore.read() == nil)
        accountEmail = session?.email
        isOwner = demo || session == nil || UserDefaults.standard.bool(forKey: Self.ownerKey)
        if !isLocked { loadCache() }
    }

    private static let ownerKey = "log.account.owner"

    /// What the next request signs in with.
    public func credential() async -> LogCredential? {
        if isDemo { return .passcode("demo") }
        return await LogCredentials.shared.current()
    }

    /// Signed in with an account (not only the passcode).
    public var hasAccount: Bool { !isDemo && SessionStore.read() != nil }

    /// A new account that hasn't finished first-run setup.
    public var needsOnboarding: Bool {
        guard !isDemo, !isLocked, let d = dashboard, d.account?.kind == "user" else { return false }
        return d.profile?.onboardedAt == nil
    }

    /// How "Log a meal" works: the Grok Log bot (the owner, unless changed) or in the app.
    public var mealLoggingInApp: Bool {
        if let mode = dashboard?.profile?.settings?.mealLogging { return mode == "app" }
        return !isOwner
    }

    // MARK: Loading

    /// First launch work: refresh, then an Apple Health catch-up if native sync is on.
    public func start() async {
        guard !isLocked else { return }
        await refresh(syncHealth: true)
    }

    /// Fetch the payload. With `syncHealth`, run the native Apple Health sync first (last 2 days).
    public func refresh(syncHealth: Bool = false) async {
        guard !isLocked, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if syncHealth, let sync = healthSync, !isDemo { await sync(2) }
        if isDemo { loadDemo(); return }
        guard let cred = await credential() else { lock(); return }
        await flushQueue(cred)
        do {
            let (d, data) = try await LogAPI.fetchDashboard(cred)
            apply(d)
            fromCache = false
            refreshFailed = false
            errorMessage = nil
            saveCache(data)
        } catch LogError.unauthorized {
            if case .session = cred {
                SessionStore.clear()
                accountEmail = nil
                if PasscodeStore.read() != nil { Task { await self.refresh() }; return }
                errorMessage = "You were signed out. Sign in again."
            } else {
                errorMessage = "That passcode didn’t work. Enter it again."
            }
            lock()
        } catch {
            refreshFailed = true
            errorMessage = (error as? LogError)?.message ?? "Couldn’t refresh."
        }
    }

    // MARK: Lock

    /// Check a passcode against the log; keep it in the Keychain if it works.
    public func unlock(_ code: String) async -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "Enter your passcode."; return false }
        do {
            let (d, data) = try await LogAPI.fetchDashboard(passcode: trimmed)
            PasscodeStore.write(trimmed)
            isOwner = true
            apply(d)
            fromCache = false
            refreshFailed = false
            errorMessage = nil
            saveCache(data)
            isLocked = false
            onLockChange?(false)
            return true
        } catch LogError.unauthorized {
            errorMessage = "That passcode didn’t work."
            return false
        } catch {
            errorMessage = (error as? LogError)?.message ?? "Couldn’t reach the log."
            return false
        }
    }

    /// Signed in with Google, Apple or email: keep the session, link the passcode log if this phone
    /// has the passcode and the account is new, then load. Returns an error sentence, or nil.
    @discardableResult
    public func signIn(_ result: LogAuth.Result) async -> String? {
        SessionStore.write(result.session)
        accountEmail = result.session.email
        var owner = result.owner
        if !owner, let code = PasscodeStore.read() {
            // The owner moving from the passcode to an account: bring the log along.
            if (try? await LogAuth.claim(accessToken: result.session.accessToken, passcode: code)) != nil { owner = true }
        }
        isOwner = owner
        UserDefaults.standard.set(owner, forKey: Self.ownerKey)
        clearCache()
        dashboard = nil
        do {
            let (d, data) = try await LogAPI.fetchDashboard(.session(result.session.accessToken))
            apply(d)
            fromCache = false
            refreshFailed = false
            errorMessage = nil
            saveCache(data)
            let changed = isLocked
            isLocked = false
            if changed { onLockChange?(false) }
            return nil
        } catch {
            let msg = (error as? LogError)?.message ?? "Couldn’t load your log."
            errorMessage = msg
            return msg
        }
    }

    /// Link the passcode log to the signed-in account (from Account). Throws LogError.
    public func linkPasscodeLog(_ code: String) async throws {
        guard SessionStore.read() != nil else { throw LogError.server("Sign in first.") }
        guard case .session(let token)? = await LogCredentials.shared.current() else { throw LogError.unauthorized }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        try await LogAuth.claim(accessToken: token, passcode: trimmed)
        PasscodeStore.write(trimmed)
        isOwner = true
        UserDefaults.standard.set(true, forKey: Self.ownerKey)
        await refresh()
    }

    /// Sign out of the account (and forget the passcode) on this phone.
    public func signOut() async {
        if let s = SessionStore.read() { await LogAuth.signOut(accessToken: s.accessToken) }
        lock()
    }

    /// Forget the sign-in, the passcode and the saved data on this phone.
    public func lock() {
        guard !isDemo else { return }
        SessionStore.clear()
        writeQueue([])
        accountEmail = nil
        UserDefaults.standard.removeObject(forKey: Self.ownerKey)
        isOwner = true
        PasscodeStore.clear()
        dashboard = nil
        dataTime = nil
        clearCache()
        let changed = !isLocked
        isLocked = true
        if changed { onLockChange?(true) }
    }

    // MARK: Writes

    /// Upload a JPEG and link it to the weigh-in, then refresh. Throws LogError.
    public func uploadProgressPhoto(jpeg: Data, weightLb: Double, weightId: String?, takenAt: String) async throws {
        if isDemo { return }
        guard jpeg.count > 0, jpeg.count <= 2_097_152 else { throw LogError.server("That photo is too large.") }
        guard let code = await credential() else { lock(); throw LogError.unauthorized }
        var signPayload: [String: Any] = ["weight_lb": weightLb, "taken_at": takenAt, "time_zone": LogTime.zone.identifier]
        if let weightId, !weightId.isEmpty { signPayload["weight_id"] = weightId }
        let signed: [String: Any]
        do { signed = try await LogAPI.write("progress_photo_sign", payload: signPayload, credential: code) }
        catch LogError.unauthorized { lock(); throw LogError.unauthorized }
        if (signed["ok"] as? Bool) == false {
            throw LogError.server((signed["error"] as? String) ?? "sign_failed")
        }
        guard let urlString = signed["signed_url"] as? String, let uploadURL = URL(string: urlString),
              let path = signed["path"] as? String, !path.isEmpty else {
            throw LogError.server("Could not start the photo upload.")
        }
        try await LogAPI.putSigned(uploadURL, body: jpeg, contentType: "image/jpeg")
        var savePayload: [String: Any] = [
            "path": path,
            "weight_lb": weightLb,
            "taken_at": takenAt,
            "byte_size": jpeg.count,
        ]
        if let weightId, !weightId.isEmpty { savePayload["weight_id"] = weightId }
        let saved: [String: Any]
        do { saved = try await LogAPI.write("progress_photo_save", payload: savePayload, credential: code) }
        catch LogError.unauthorized { lock(); throw LogError.unauthorized }
        if (saved["ok"] as? Bool) == false {
            throw LogError.server((saved["error"] as? String) ?? "save_failed")
        }
        await refresh()
    }

    /// Delete one progress photo (the row and the private object), then refresh.
    public func deleteProgressPhoto(id: String) async throws {
        let result = try await write("progress_photo_delete", ["id": id])
        if (result["ok"] as? Bool) == false {
            throw LogError.server((result["error"] as? String) ?? "delete_failed")
        }
    }

    /// Send a log-write action, then refresh in the background. Throws LogError.
    @discardableResult
    public func write(_ action: String, _ payload: [String: Any]) async throws -> [String: Any] {
        if isDemo { return ["ok": true, "demo": true] }
        guard let code = await credential() else { lock(); throw LogError.unauthorized }
        do {
            let result = try await LogAPI.write(action, payload: payload, credential: code)
            Task { await self.refresh() }
            return result
        } catch LogError.unauthorized {
            lock()
            throw LogError.unauthorized
        } catch LogError.network(let msg) {
            // No connection: keep simple logs on the phone and send them when it's back.
            guard Self.queueable.contains(action) else { throw LogError.network(msg) }
            var p = payload
            if action == "food_thought", p["at"] == nil { p["at"] = ISO8601DateFormatter().string(from: Date()) }
            enqueue(action, p)
            return ["ok": true, "queued": true]
        }
    }

    // MARK: Offline queue

    /// Logs that are safe to send later, in order, once the connection is back.
    static let queueable: Set<String> = ["food_thought", "checkin_upsert", "side_effect_upsert", "earn_it", "meal_log", "measurement"]
    /// Waiting to send (shown on Today so nothing looks lost).
    public private(set) var pendingCount = 0

    private var queueURL: URL? { cacheURL?.deletingLastPathComponent().appendingPathComponent("pending.json") }

    private func readQueue() -> [[String: Any]] {
        guard let url = queueURL, let data = try? Data(contentsOf: url),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list
    }

    private func writeQueue(_ list: [[String: Any]]) {
        guard let url = queueURL else { return }
        pendingCount = list.count
        if list.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: list) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func enqueue(_ action: String, _ payload: [String: Any]) {
        var list = readQueue()
        guard list.count < 200 else { return }
        list.append(["action": action, "payload": payload])
        writeQueue(list)
    }

    /// Send what's waiting. Stops at the first network failure; drops one the log rejects.
    private func flushQueue(_ cred: LogCredential) async {
        var list = readQueue()
        pendingCount = list.count
        guard !list.isEmpty else { return }
        while let first = list.first {
            guard let action = first["action"] as? String, let payload = first["payload"] as? [String: Any] else {
                list.removeFirst(); continue
            }
            do {
                _ = try await LogAPI.write(action, payload: payload, credential: cred)
                list.removeFirst()
            } catch LogError.network {
                break
            } catch {
                list.removeFirst()
            }
        }
        writeQueue(list)
    }

    // MARK: Cache (the last payload, so the app opens with data)

    private var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("log", isDirectory: true).appendingPathComponent("dashboard.json")
    }

    private func loadCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url), let d = try? Dashboard.decode(data) else { return }
        apply(d)
        dataTime = d.asOfDate
        fromCache = true
    }

    /// Show a payload: the person's time zone and plan dates first, so every screen counts days
    /// the same way.
    private func apply(_ d: Dashboard) {
        Self.applyPlan(d)
        dashboard = d
        dataTime = d.asOfDate ?? Date()
        if let a = d.account, a.kind == "owner" { isOwner = true }
        onDataChange?()
    }

    /// Time zone and the GLP-1 journey dates from the profile, else from the logged shots.
    public static func applyPlan(_ d: Dashboard) {
        if let id = d.profile?.timeZone, let z = TimeZone(identifier: id) {
            LogTime.use(zone: z)
        } else if d.account?.kind == "user" {
            LogTime.use(zone: .current)
        }
        // The original log keeps its built-in dates unless settings say otherwise.
        let s = d.profile?.settings
        guard d.account?.kind == "user" || s?.journeyStart != nil || s?.switchOn != nil else { return }
        let shots = d.doses.filter { $0.skipped != true }.compactMap { dose in dose.takenDate.map { ($0, dose.compound) } }.sorted { $0.0 < $1.0 }
        if let key = s?.journeyStart, let t = LogTime.parse(key) {
            LogTime.tirzStart = t
        } else if let first = shots.first {
            LogTime.tirzStart = first.0
        } else if let w = d.weights.compactMap({ LogTime.parse($0.measuredAt) }).min() {
            LogTime.tirzStart = w
        }
        let regimenCompound: String? = d.regimens.first(where: { Dose.isGLP1($0.compound) })?.compound
        let firstCompound: String = shots.first?.1 ?? regimenCompound ?? "tirzepatide"
        LogTime.journeyName = firstCompound.capitalized
        if let key = s?.switchOn, let t = LogTime.parse(key) {
            LogTime.switchStart = t
            LogTime.switchName = (s?.switchCompound ?? "retatrutide").capitalized
        } else {
            LogTime.switchStart = nil
        }
    }

    private func saveCache(_ data: Data) {
        guard let url = cacheURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func clearCache() {
        guard let url = cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func loadDemo() {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "json", subdirectory: "public"),
              let data = try? Data(contentsOf: url),
              let d = try? Dashboard.decode(data) else {
            errorMessage = "No demo data in this build."
            return
        }
        apply(d)
        fromCache = false
    }
}
