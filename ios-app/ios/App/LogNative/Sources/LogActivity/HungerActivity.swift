import Foundation
import ActivityKit
import LogCore

/// The hunger Live Activity: today's food thoughts (hunger signals) as a timeline, calories left
/// and the estimated GLP-1 level, on the Lock Screen and in the Dynamic Island, with buttons that
/// log a food thought without opening the app. The app starts it from Today and keeps it
/// current; the LogWidgets extension draws it.
public struct HungerAttributes: ActivityAttributes {
    public struct Thought: Codable, Hashable, Sendable {
        /// Minutes since midnight, Central time.
        public var minute: Int
        /// 1 passing thought, 2 strong pull, 3 craving
        public var strength: Int
        public init(minute: Int, strength: Int) { self.minute = minute; self.strength = strength }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var day: String
        public var thoughts: [Thought]
        public var caloriesEaten: Int?
        public var calorieTarget: Int?
        public var levelMg: Double?
        /// "Strong pull at 3:10 PM"
        public var lastLine: String?
        public var updated: Date

        public init(day: String, thoughts: [Thought], caloriesEaten: Int?, calorieTarget: Int?, levelMg: Double?, lastLine: String?, updated: Date) {
            self.day = day; self.thoughts = thoughts; self.caloriesEaten = caloriesEaten; self.calorieTarget = calorieTarget
            self.levelMg = levelMg; self.lastLine = lastLine; self.updated = updated
        }

        public var caloriesLeft: Int? {
            guard let caloriesEaten, let calorieTarget else { return nil }
            return calorieTarget - caloriesEaten
        }
        public var count: Int { thoughts.count }
        public var cravings: Int { thoughts.filter { $0.strength >= 3 }.count }
    }

    public init() {}
}

public enum HungerWords {
    public static func strength(_ s: Int) -> String {
        switch s {
        case 3: return "Craving"
        case 2: return "Strong pull"
        default: return "Passing thought"
        }
    }
}

@MainActor
public enum HungerActivity {
    private static let key = "log.hungerActivity.on"

    /// The person turned it on from Today (it stays on day to day until they turn it off).
    public static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    public static var available: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    public static var running: Activity<HungerAttributes>? { Activity<HungerAttributes>.activities.first }

    /// Today's state from the dashboard.
    public static func state(_ d: Dashboard, now: Date = Date()) -> HungerAttributes.ContentState {
        let today = LogTime.today(now)
        let start = LogTime.startOfDay(today)
        let mine = d.foodThoughts.compactMap { t -> (Date, Int)? in
            guard let at = t.thoughtDate, LogTime.dayKey(at) == today else { return nil }
            return (at, Int(t.strength ?? 1))
        }.sorted { $0.0 < $1.0 }
        let thoughts = mine.map { HungerAttributes.Thought(minute: max(0, Int($0.0.timeIntervalSince(start) / 60)), strength: $0.1) }
        let last = mine.last.map { "\(HungerWords.strength($0.1)) at \(LogTime.time($0.0))" }
        let eaten = Analytics.totals(on: today, d)?.calories.map { Int($0.rounded()) }
        let target = Analytics.targets(d).calories.map { Int($0.rounded()) }
        let level = d.doses.isEmpty ? nil : Analytics.remaining(at: now, doses: d.doses, protocols: d.protocols)
        return .init(day: today, thoughts: thoughts, caloriesEaten: eaten ?? 0, calorieTarget: target, levelMg: level,
                     lastLine: last, updated: now)
    }

    /// Start (when on and none is running) or update the activity from fresh data. Ends one left
    /// over from an earlier day and starts today's.
    public static func sync(_ d: Dashboard, now: Date = Date()) async {
        guard isOn, available else {
            if !isOn { await endAll() }
            return
        }
        let s = state(d, now: now)
        let stale = Calendar.current.date(byAdding: .hour, value: 3, to: now)
        if let a = running, a.content.state.day == s.day, a.activityState == .active {
            await a.update(ActivityContent(state: s, staleDate: stale))
            return
        }
        await endAll()
        do {
            _ = try Activity.request(attributes: HungerAttributes(), content: ActivityContent(state: s, staleDate: stale), pushType: nil)
        } catch {
            // Not allowed right now (Live Activities off in Settings, or too many running).
        }
    }

    public static func endAll() async {
        for a in Activity<HungerAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Right after a button logs a thought: show it at once, before the next refresh.
    public static func appendNow(strength: Int, now: Date = Date()) async {
        guard let a = running else { return }
        var s = a.content.state
        let start = LogTime.startOfDay(s.day)
        s.thoughts.append(.init(minute: max(0, Int(now.timeIntervalSince(start) / 60)), strength: strength))
        s.lastLine = "\(HungerWords.strength(strength)) at \(LogTime.time(now))"
        s.updated = now
        await a.update(ActivityContent(state: s, staleDate: Calendar.current.date(byAdding: .hour, value: 3, to: now)))
    }
}
