import Foundation
import LogCore

/// What a sync stored (counts from the log-write responses).
public struct HealthSyncResult: Sendable {
    public var days = 0
    public var weights = 0
    public var body = 0
    public var workouts = 0
    public var metrics = 0
    public var error: String?
    public init() {}
}

/// Apple Health sync in Swift (stage 3). Placeholder: `isReady` is false, so the web app's sync
/// (ios-app/www/health.js through the Capacitor Health plugin) keeps running.
///
/// When ready it replaces health.js: the same payloads to the same `health_sync` and
/// `health_metrics` actions, a resumable history backfill, and a background refresh
/// (BGAppRefreshTask "com.pranaybop.log.healthsync", registered in AppDelegate).
public final class NativeHealthSync: @unchecked Sendable {
    public static let shared = NativeHealthSync()
    /// Flip to true when this does everything health.js does. The app then turns the web sync off.
    public static let isReady = false
    public static let backgroundTaskId = "com.pranaybop.log.healthsync"

    /// Call from application(_:didFinishLaunchingWithOptions:), before it returns.
    public static func registerBackgroundTasks() {}
    /// Call when the app goes to the background.
    public static func scheduleBackgroundRefresh() {}

    /// Sync the last `days` days. Uses the Keychain passcode.
    public func sync(days: Int) async -> HealthSyncResult {
        var r = HealthSyncResult()
        r.error = "Native Apple Health sync isn't on yet."
        return r
    }

    /// Continue the history backfill (no-op until ready).
    public func backfill() async {}
}
