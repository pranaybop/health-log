import Foundation
import HealthKit
import Observation
import LogCore

/// What the Apple Health panel shows: whether a sync is running, the last sync, the last message
/// and the backfill. NativeHealthSync updates it; HealthSyncPanel reads it. The last sync and the
/// backfill cursor are kept in UserDefaults (times and counts only, never health values).
@MainActor
@Observable
public final class HealthSyncStatus {
    public static let shared = HealthSyncStatus()

    public struct Message: Equatable, Sendable {
        public var ok: Bool
        public var text: String
    }

    public private(set) var isSyncing = false
    public private(set) var last: HealthSyncRecord?
    public private(set) var message: Message?
    public private(set) var backfill: HealthBackfillState
    /// False until the backfill has been started or decided once on this phone.
    public private(set) var hasBackfillRecord: Bool
    /// Bumped after each sync you asked for that worked (for the success haptic).
    public private(set) var manualSyncs = 0

    @ObservationIgnored private let defaults: UserDefaults
    static let lastKey = "log.native.healthSync"
    static let backfillKey = "log.native.healthBackfill"

    /// Drop the saved sync and backfill cursor. UI tests call this before the panel is created.
    public static func resetSaved() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastKey)
        defaults.removeObject(forKey: backfillKey)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        last = defaults.data(forKey: Self.lastKey).flatMap { try? decoder.decode(HealthSyncRecord.self, from: $0) }
        if let saved = defaults.data(forKey: Self.backfillKey).flatMap({ try? decoder.decode(HealthBackfillState.self, from: $0) }) {
            var b = saved
            b.running = false
            backfill = b
            hasBackfillRecord = true
        } else {
            backfill = HealthBackfillState()
            hasBackfillRecord = false
        }
    }

    // MARK: For the panel

    /// Why syncing can't run here at all, or nil.
    public var blockedReason: String? {
        if LogStore.shared.isDemo { return HealthSyncError.demo.text }
        if !HKHealthStore.isHealthDataAvailable() { return HealthSyncError.unavailable.text }
        return nil
    }

    /// The message from the last sync, else when it last synced.
    public var statusLine: String {
        if let m = message { return m.text }
        if let l = last { return HealthText.lastSynced(l.at) }
        return "Not synced yet"
    }

    public var isError: Bool { message.map { !$0.ok } ?? false }
    public var backfillLine: String { HealthText.backfill(backfill) }
    public var backfillButtonTitle: String { HealthText.backfillButton(backfill) }

    // MARK: Updates (NativeHealthSync)

    /// Start a sync, or nil to skip it (one is running, or a catch-up ran under a minute ago).
    func beginSync(_ mode: NativeHealthSync.Mode, days: Int, now: Date = Date()) -> Int? {
        guard !isSyncing else { return nil }
        if mode == .catchUp, let l = last, l.at <= now, now.timeIntervalSince(l.at) < 60 { return nil }
        isSyncing = true
        if mode == .manual { message = nil }
        if mode == .catchUp && last == nil { return max(days, 30) }
        return max(1, days)
    }

    func endSync(_ mode: NativeHealthSync.Mode, _ result: HealthSyncResult, record: HealthSyncRecord?) {
        isSyncing = false
        if let record {
            last = record
            if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.lastKey) }
        }
        if let e = result.error {
            message = Message(ok: false, text: e)
        } else if mode == .manual {
            message = Message(ok: true, text: HealthText.summary(result))
            manualSyncs += 1
        } else {
            message = nil
        }
    }

    /// Start (or restart) the backfill; nil if it's running or already done.
    func beginBackfill(restart: Bool) -> HealthBackfillState? {
        guard !backfill.running else { return nil }
        var b = backfill
        if restart {
            b = HealthBackfillState()
        } else if b.done {
            return nil
        }
        b.running = true
        b.error = nil
        setBackfill(b)
        return b
    }

    func setBackfill(_ b: HealthBackfillState) {
        backfill = b
        hasBackfillRecord = true
        var saved = b
        saved.running = false
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.backfillKey) }
    }
}
