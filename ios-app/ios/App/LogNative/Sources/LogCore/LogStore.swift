import Foundation
import Observation

/// The app's shared state: the dashboard payload, whether you're signed in, and refresh/write.
/// Screens read `LogStore.shared` (it's also put in the SwiftUI environment).
///
/// Opens instantly from the last payload saved on the phone, then refreshes. A rejected passcode
/// locks the app. Debug builds launched with `-demo <tab>` (the CI simulator check) read made-up
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
    public let isDemo: Bool
    /// `-demo <tab>` and `-section <id>` launch arguments (debug builds only).
    public let demoTab: String?
    public let demoSection: String?

    /// Set by the app: run the native Apple Health sync for the last `days` days, then return.
    @ObservationIgnored public var healthSync: ((_ days: Int) async -> Void)?
    /// Set by the app: called when the app locks or unlocks.
    @ObservationIgnored public var onLockChange: ((_ locked: Bool) -> Void)?

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
        isLocked = demo ? false : PasscodeStore.read() == nil
        if !isLocked { loadCache() }
    }

    /// The passcode for API calls (never shown or logged).
    public var passcode: String? { isDemo ? "demo" : PasscodeStore.read() }

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
        guard let code = passcode else { lock(); return }
        do {
            let (d, data) = try await LogAPI.fetchDashboard(passcode: code)
            dashboard = d
            dataTime = d.asOfDate ?? Date()
            fromCache = false
            refreshFailed = false
            errorMessage = nil
            saveCache(data)
        } catch LogError.unauthorized {
            errorMessage = "That passcode didn’t work. Enter it again."
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
            dashboard = d
            dataTime = d.asOfDate ?? Date()
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

    /// Forget the passcode and the saved data on this phone.
    public func lock() {
        guard !isDemo else { return }
        PasscodeStore.clear()
        dashboard = nil
        dataTime = nil
        clearCache()
        let changed = !isLocked
        isLocked = true
        if changed { onLockChange?(true) }
    }

    /// The shell calls this when the web view locked or unlocked on its own.
    public func syncLockFromKeychain() {
        let locked = isDemo ? false : PasscodeStore.read() == nil
        guard locked != isLocked else { return }
        if locked { dashboard = nil; clearCache() } else { loadCache() }
        isLocked = locked
    }

    // MARK: Writes

    /// Upload a JPEG and link it to the weigh-in, then refresh. Throws LogError.
    public func uploadProgressPhoto(jpeg: Data, weightLb: Double, weightId: String?, takenAt: String) async throws {
        if isDemo { return }
        guard jpeg.count > 0, jpeg.count <= 2_097_152 else { throw LogError.server("That photo is too large.") }
        guard let code = passcode else { lock(); throw LogError.unauthorized }
        var signPayload: [String: Any] = ["weight_lb": weightLb, "taken_at": takenAt]
        if let weightId, !weightId.isEmpty { signPayload["weight_id"] = weightId }
        let signed: [String: Any]
        do { signed = try await LogAPI.write("progress_photo_sign", payload: signPayload, passcode: code) }
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
        do { saved = try await LogAPI.write("progress_photo_save", payload: savePayload, passcode: code) }
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
        guard let code = passcode else { lock(); throw LogError.unauthorized }
        do {
            let result = try await LogAPI.write(action, payload: payload, passcode: code)
            Task { await self.refresh() }
            return result
        } catch LogError.unauthorized {
            lock()
            throw LogError.unauthorized
        }
    }

    // MARK: Cache (the last payload, so the app opens with data)

    private var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("log", isDirectory: true).appendingPathComponent("dashboard.json")
    }

    private func loadCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url), let d = try? Dashboard.decode(data) else { return }
        dashboard = d
        dataTime = d.asOfDate
        fromCache = true
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
        dashboard = d
        dataTime = d.asOfDate ?? Date()
        fromCache = false
    }
}
