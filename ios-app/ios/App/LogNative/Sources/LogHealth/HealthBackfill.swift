import Foundation
import LogCore

/// It walks back from yesterday in windows that start at 10 days and grow to 60 while there's
/// little data (shrinking if a read hits its limit), stops at 2015-01-01 or after a year with
/// nothing in it, and saves the cursor after every window.
public struct HealthBackfillState: Codable, Equatable, Sendable {
    public static let floor = "2015-01-01"
    public static let emptyLimit = 365

    public var cursor: String?
    public var oldest: String?
    public var done = false
    public var values = 0
    public var size: Int?
    public var empty: Int?
    public var error: String?
    public var running = false
    /// Set when the log already had the history before the native sync started (see
    /// historyAlreadyThere): the first Apple Health day in the log.
    public var alreadyThere: String?

    public init() {}

    public var windowSize: Int { size ?? 10 }
    public var emptyDays: Int { empty ?? 0 }

    /// The newest day of the next window: the day before the cursor, else yesterday.
    public func nextEnd(today: String) -> String {
        cursor.map { LogTime.shift($0, -1) } ?? LogTime.shift(today, -1)
    }

    public static func windowStart(end: String, size: Int) -> String {
        let s = LogTime.shift(end, -(size - 1))
        return s < floor ? floor : s
    }

    /// Keep walking while there are days above the floor and the last year wasn't empty.
    public static func shouldContinue(end: String, empty: Int) -> Bool {
        end >= floor && empty < emptyLimit
    }

    /// After sending a window [startKey, endKey]: move the cursor, track the oldest day with data,
    /// count empty days, resize the next window, add what the log stored.
    public mutating func record(startKey: String, endKey: String, batch: HealthBatch, stored: Int) {
        let e = batch.found > 0 ? 0 : emptyDays + LogTime.dayDiff(endKey, startKey) + 1
        if let first = batch.foundDays.first, oldest == nil || first < (oldest ?? first) {
            oldest = first
        }
        let s = windowSize
        size = batch.maxCount < HealthAggregate.sampleLimit / 4 ? min(s * 2, 60) : max(5, s / 2)
        cursor = startKey
        empty = e
        values += stored
    }

    /// Whether the log already holds the Apple Health history, so the backfill can start "done".
    public static func historyAlreadyThere(firstHealthDay: String?, earliestMetricDay: String?, today: String) -> Bool {
        guard let f = firstHealthDay, f.count >= 10, let m = earliestMetricDay, m.count >= 10 else { return false }
        return LogTime.dayDiff(today, String(f.prefix(10))) >= 365 && LogTime.dayDiff(today, String(m.prefix(10))) >= 100
    }

    public static func historyAlreadyThere(_ d: Dashboard, today: String) -> Bool {
        historyAlreadyThere(firstHealthDay: d.healthSpan?.firstDay, earliestMetricDay: earliestMetricDay(d), today: today)
    }

    public static func earliestMetricDay(_ d: Dashboard) -> String? {
        d.healthMetrics.values.compactMap { points in points.map { String($0.day.prefix(10)) }.min() }.min()
    }

    /// The state when the history is already in the log.
    public static func alreadyDone(firstDay: String?) -> HealthBackfillState {
        var b = HealthBackfillState()
        b.done = true
        b.alreadyThere = firstDay.map { String($0.prefix(10)) }
        return b
    }
}

public enum HealthText {
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// 1234 -> "1,234"
    public static func num(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func count(_ n: Int, _ word: String) -> String {
        "\(num(n)) \(word)\(n == 1 ? "" : "s")"
    }

    /// "Synced 2 days, 1 weigh-in and 140 other values."
    public static func summary(_ r: HealthSyncResult) -> String {
        var parts: [String] = []
        let named: [(Int, String)] = [(r.days, "day"), (r.weights, "weigh-in"), (r.body, "body reading"), (r.workouts, "workout")]
        for (n, w) in named where n != 0 { parts.append(count(n, w)) }
        if r.metrics != 0 { parts.append(count(r.metrics, "other value")) }
        guard let last = parts.last else { return "Synced. Nothing new in Apple Health." }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + last : last
        return "Synced \(list)."
    }

    /// "Last synced Nov 24, 9:30 AM"
    public static func lastSynced(_ at: Date) -> String {
        "Last synced \(LogTime.shortDate(at)), \(LogTime.time(at))"
    }

    static func monthYear(_ key: String) -> String { LogTime.monthYear(LogTime.noon(key)) }

    public static func backfill(_ b: HealthBackfillState) -> String {
        let n = count(b.values, "value")
        if b.running {
            return b.cursor.map { "Backfilling history: back to \(monthYear($0)) so far, \(n) saved." } ?? "Backfilling history: starting…"
        }
        if let error = b.error {
            var reason = error.hasPrefix("Couldn’t sync: ") ? String(error.dropFirst("Couldn’t sync: ".count)) : error
            while reason.hasSuffix(".") { reason.removeLast() }
            let at = b.cursor.map { " at \(monthYear($0))" } ?? ""
            return "Backfill stopped\(at): \(reason). It tries again next time the app opens."
        }
        if b.done {
            if let there = b.alreadyThere, b.values == 0, b.oldest == nil {
                return "History is already in the log, going back to \(monthYear(there))."
            }
            return b.oldest.map { "History backfilled: \(n) saved, going back to \(monthYear($0))." }
                ?? "History backfilled. Apple Health had nothing older to add."
        }
        if let c = b.cursor { return "History backfilled back to \(monthYear(c)) so far. It carries on next time the app opens." }
        return ""
    }

    public static func backfillButton(_ b: HealthBackfillState) -> String {
        if b.running { return "Backfilling…" }
        if b.done { return "Backfill again" }
        return b.cursor == nil ? "Backfill history" : "Continue backfill"
    }

    public static func error(_ error: Error) -> String {
        if let e = error as? HealthSyncError { return e.text }
        if error is CancellationError { return "Couldn’t sync: it was stopped before it finished." }
        if let e = error as? LogError {
            if e == .unauthorized { return "Your sign-in ran out. Sign in again." }
            return "Couldn’t sync: \(e.message)"
        }
        return "Couldn’t sync: \(error.localizedDescription)"
    }
}

/// Reasons a sync can't run, in plain words.
public enum HealthSyncError: Error, Equatable, Sendable {
    case demo
    case locked
    case unavailable
    case deviceLocked
    case notAllowedYet

    public var text: String {
        switch self {
        case .demo: return "Apple Health sync is off in demo mode."
        case .locked: return "Unlock Log to sync Apple Health."
        case .unavailable: return "Apple Health isn't available on this device."
        case .deviceLocked: return "Apple Health can't be read while the iPhone is locked."
        case .notAllowedYet: return "Apple Health access hasn't been allowed yet. Tap Sync to allow it."
        }
    }
}
