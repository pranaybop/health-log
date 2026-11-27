import Foundation
import BackgroundTasks
import HealthKit
import UIKit
import LogCore

/// Apple Health sync in Swift. HealthKit reads (HealthAggregate) go to the `health_sync` and
/// `health_metrics` log-write actions with the Keychain passcode.
///
/// - sync(days:): the recent catch-up. The app calls it with 2 at launch, on pull to refresh and
///   on coming back to the app (the first one on this phone takes 30 days, like the web's).
/// - The history backfill carries on after a foreground catch-up until it's done; never in the
///   background task.
/// - A BGAppRefreshTask ("com.pranaybop.log.healthsync") catches up on the last 2 days about
///   hourly while the app is closed.
/// Never runs in demo mode, never asks for Health access in the background, never logs values.
public final class NativeHealthSync: @unchecked Sendable {
    public static let shared = NativeHealthSync()
    public static let backgroundTaskId = "com.pranaybop.log.healthsync"

    enum Mode: Sendable, Equatable {
        /// The app's own catch-up (launch, pull to refresh, coming back).
        case catchUp
        /// You tapped Sync in the panel.
        case manual
        /// The background refresh task.
        case background
    }

    let reader = HealthKitReader()

    public static var isAvailable: Bool { HealthKitReader.isAvailable }

    // MARK: Background refresh

    private static let registration = NSLock()
    private static var registered = false

    /// Call from application(_:didFinishLaunchingWithOptions:), before it returns.
    public static func registerBackgroundTasks() {
        registration.lock()
        defer { registration.unlock() }
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            shared.handle(refresh)
        }
    }

    /// Call when the app goes to the background: ask iOS for a catch-up in about an hour.
    public static func scheduleBackgroundRefresh() {
        guard !isDemoLaunch, PasscodeStore.read() != nil || SessionStore.read() != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The app was launched with made-up data (debug builds), same check as LogStore's.
    static var isDemoLaunch: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        return false
        #endif
    }

    private func handle(_ task: BGAppRefreshTask) {
        Self.scheduleBackgroundRefresh()
        let work = Task {
            let r = await self.run(days: 2, mode: .background)
            if !Task.isCancelled {
                // Fresh numbers for next time, and a fresh look at the log: the reminders and the
                // hunger Live Activity follow the store, so a dose logged elsewhere (the bot)
                // cancels its "overdue" reminder and a new day starts a new timeline.
                await LogStore.shared.refresh()
            }
            task.setTaskCompleted(success: r.error == nil && !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: Syncing

    /// Sync the last `days` days. Uses the Keychain passcode. The app's catch-up: skipped if one
    /// ran under a minute ago.
    public func sync(days: Int) async -> HealthSyncResult {
        await run(days: days, mode: .catchUp)
    }

    /// The panel's Sync button: always runs, says what it stored, then refreshes the screens.
    public func syncNow(days: Int) async -> HealthSyncResult {
        let r = await run(days: days, mode: .manual)
        if r.error == nil, !r.skipped { await LogStore.shared.refresh() }
        return r
    }

    func run(days: Int, mode: Mode) async -> HealthSyncResult {
        guard let n = await MainActor.run(body: { HealthSyncStatus.shared.beginSync(mode, days: days) }) else {
            var skipped = HealthSyncResult()
            skipped.skipped = true
            if mode != .background { startBackfillIfNeeded() }
            return skipped
        }
        let (result, record) = await performSync(days: n, mode: mode)
        await MainActor.run { HealthSyncStatus.shared.endSync(mode, result, record: record) }
        if mode != .background { startBackfillIfNeeded() }
        return result
    }

    /// health.js syncAppleHealth: newest first, 10 days at a time: daily totals, every metric,
    /// weigh-ins and body fat from the last 60 days or more (first window only), and workouts.
    private func performSync(days: Int, mode: Mode) async -> (HealthSyncResult, HealthSyncRecord?) {
        var totals = HealthSyncResult()
        do {
            let code = try await prepare(mode: mode)
            let now = Date()
            let today = LogTime.today(now)
            let firstKey = LogTime.shift(today, -(days - 1))
            let weightStart = min(LogTime.startOfDay(firstKey), now.addingTimeInterval(-60 * 86400))
            var endKey = today
            var first = true
            while endKey >= firstKey {
                try Task.checkCancellation()
                let back = LogTime.shift(endKey, -9)
                let startKey = back < firstKey ? firstKey : back
                let batch = await collectSafe(startKey, endKey, includeDays: true,
                                              weightStart: first ? weightStart : nil, skipWeights: !first)
                let got = try await send(batch, passcode: code)
                totals.add(got)
                first = false
                endKey = LogTime.shift(startKey, -1)
            }
            return (totals, HealthSyncRecord(at: Date(), result: totals))
        } catch {
            totals.error = HealthText.error(error)
            return (totals, nil)
        }
    }

    /// Checks before reading: not demo, unlocked, Health on this device and readable, access asked.
    /// The permission sheet is only shown in the foreground (never from the background task).
    private func prepare(mode: Mode) async throws -> LogCredential {
        let demo = await MainActor.run { LogStore.shared.isDemo }
        if demo { throw HealthSyncError.demo }
        guard let code = await LogCredentials.shared.current() else { throw HealthSyncError.locked }
        guard HealthKitReader.isAvailable else { throw HealthSyncError.unavailable }
        let readable = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        guard readable else { throw HealthSyncError.deviceLocked }
        if mode != .background, await Self.waitUntilActive() {
            try await reader.authorizeIfNeeded()
        } else if await reader.needsAuthorization() {
            throw HealthSyncError.notAllowedYet
        }
        return code
    }

    /// health.js collectSafe: split the window in half (down to one day) when a read hits its limit.
    func collectSafe(_ startKey: String, _ endKey: String, includeDays: Bool, weightStart: Date?, skipWeights: Bool) async -> HealthBatch {
        let data = await reader.collect(startKey: startKey, endKey: endKey, includeDays: includeDays,
                                        weightStart: weightStart, skipWeights: skipWeights)
        guard data.truncated, let olderEnd = HealthAggregate.splitEnd(startKey: startKey, endKey: endKey) else { return data }
        let newer = await collectSafe(LogTime.shift(olderEnd, 1), endKey, includeDays: includeDays,
                                      weightStart: weightStart, skipWeights: skipWeights)
        let older = await collectSafe(startKey, olderEnd, includeDays: includeDays,
                                      weightStart: weightStart, skipWeights: skipWeights)
        return HealthAggregate.merge(older: older, newer: newer)
    }

    /// health.js sendHealth: the window in small requests; what the log stored.
    private func send(_ batch: HealthBatch, passcode: LogCredential) async throws -> HealthSyncResult {
        var totals = HealthSyncResult()
        for request in HealthPayload.requests(for: batch) {
            try Task.checkCancellation()
            let r = try await LogAPI.write(request.action, payload: request.payload, credential: passcode)
            totals.add(response: r)
        }
        return totals
    }

    // MARK: History backfill

    /// Continue the history backfill (it stops by itself when done).
    public func backfill() async {
        await backfill(restart: false)
    }

    /// health.js backfillHealth: walk back through history from yesterday, sending metrics,
    /// weigh-ins, body composition and workouts (not daily totals: older days of those came from
    /// the Health export). Saves the cursor after every window; pauses if the app leaves the
    /// foreground and carries on next time. `restart` starts again from yesterday ("Backfill again").
    public func backfill(restart: Bool) async {
        let leaving = await Self.inBackground()
        if leaving { return }
        guard var b = await MainActor.run(body: { HealthSyncStatus.shared.beginBackfill(restart: restart) }) else { return }
        let startValues = b.values
        do {
            let code = try await prepare(mode: .manual)
            var endKey = b.nextEnd(today: LogTime.today())
            while HealthBackfillState.shouldContinue(end: endKey, empty: b.emptyDays) {
                try Task.checkCancellation()
                if await Self.inBackground() { break }
                let startKey = HealthBackfillState.windowStart(end: endKey, size: b.windowSize)
                let batch = await collectSafe(startKey, endKey, includeDays: false, weightStart: nil, skipWeights: false)
                let got = try await send(batch, passcode: code)
                b.record(startKey: startKey, endKey: endKey, batch: batch, stored: got.values)
                let progress = b
                await MainActor.run { HealthSyncStatus.shared.setBackfill(progress) }
                endKey = LogTime.shift(startKey, -1)
            }
            b.running = false
            b.done = !HealthBackfillState.shouldContinue(end: endKey, empty: b.emptyDays)
        } catch {
            b.running = false
            // Leaving the app cuts the request off: that's a pause, not an error.
            let paused = await Self.inBackground()
            if !paused { b.error = HealthText.error(error) }
        }
        let final = b
        await MainActor.run { HealthSyncStatus.shared.setBackfill(final) }
        if final.values > startValues { await LogStore.shared.refresh() }
    }

    /// After a foreground catch-up: carry on with the backfill unless it's done. The first time on
    /// this phone, look at the payload first: if the history is already in the log (the web
    /// backfill sent it), start "done" instead (HealthBackfillState.historyAlreadyThere).
    func startBackfillIfNeeded() {
        Task.detached(priority: .utility) { [self] in
            let (decided, done, running, demo) = await MainActor.run {
                let s = HealthSyncStatus.shared
                return (s.hasBackfillRecord, s.backfill.done, s.backfill.running, LogStore.shared.isDemo)
            }
            if demo || done || running { return }
            if !decided {
                // The app refreshes the payload right after its catch-up: wait for that (up to 20 s).
                var verdict: (already: Bool, firstDay: String?)?
                for _ in 0..<40 {
                    let check: (busy: Bool, verdict: (already: Bool, firstDay: String?)?) = await MainActor.run {
                        let store = LogStore.shared
                        guard !store.isRefreshing else { return (true, nil) }
                        guard let d = store.dashboard else { return (false, nil) }
                        return (false, (HealthBackfillState.historyAlreadyThere(d, today: LogTime.today()), d.healthSpan?.firstDay))
                    }
                    if !check.busy {
                        verdict = check.verdict
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard let verdict else { return } // no payload yet: decide next time
                if verdict.already {
                    let seeded = HealthBackfillState.alreadyDone(firstDay: verdict.firstDay)
                    await MainActor.run {
                        if !HealthSyncStatus.shared.hasBackfillRecord { HealthSyncStatus.shared.setBackfill(seeded) }
                    }
                    return
                }
            }
            await self.backfill(restart: false)
        }
    }

    @MainActor
    private static func inBackground() -> Bool {
        UIApplication.shared.applicationState == .background
    }

    /// At launch the app can still be inactive for a moment: give it a few seconds to come up
    /// before showing the permission sheet. False if it never did.
    private static func waitUntilActive() async -> Bool {
        for _ in 0..<20 {
            let state = await MainActor.run { UIApplication.shared.applicationState }
            if state == .active { return true }
            if state == .background { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
}
