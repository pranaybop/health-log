import Foundation
import UserNotifications
import LogCore

/// Progress notifications, on this phone only: one when a weigh-in passes a 5 lb milestone (or
/// the goal), and a weekly recap on Sunday evening with the trend's change, pace and goal date.
/// Off until turned on in Log › Reminders. Runs whenever the data changes (ReminderScheduler).
@MainActor
enum ProgressNotifier {
    static let enabledKey = "log.progressAlerts"
    static let notifiedKey = "log.progressAlerts.milestones"
    static let recapID = "log.progress.recap"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Turning it on asks for notification permission first. Returns whether it's on.
    static func setEnabled(_ on: Bool) async -> Bool {
        if on {
            guard await ReminderScheduler.shared.authorize() else { return false }
        }
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on, let d = LogStore.shared.dashboard {
            check(d)
        } else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [recapID])
        }
        return on
    }

    static func progress(_ d: Dashboard, now: Date) -> WeightProgress.Summary? {
        WeightProgress.make(Analytics.smoothWeights(d), startLb: d.profile?.startWeightLb, goalLb: d.profile?.goalWeightLb,
                            since: Analytics.Trends.firstGlp1At(d), now: now)
    }

    static func check(_ d: Dashboard, now: Date = Date()) {
        guard enabled, let p = progress(d, now: now) else { return }
        let defaults = UserDefaults.standard
        let firstRun = defaults.object(forKey: notifiedKey) == nil
        var notified = Set(defaults.array(forKey: notifiedKey) as? [Double] ?? [])
        let reached = p.milestones.filter { $0.reached != nil }
        // Milestones already behind you when this was turned on aren't news.
        let fresh = firstRun ? [] : reached.filter { !notified.contains($0.lb) }
        for m in reached { notified.insert(m.lb) }
        defaults.set(Array(notified), forKey: notifiedKey)
        if let m = fresh.last { post(milestone: m, p) }
        scheduleRecap(p, now: now)
    }

    static func post(milestone m: WeightProgress.Milestone, _ p: WeightProgress.Summary) {
        let c = UNMutableNotificationContent()
        if m.isGoal {
            c.title = "Goal reached: \(Fmt.num(m.lb, 0)) lb"
            c.body = "You've lost \(Fmt.num(p.done, 1)) lb since you started. That's the goal you set."
        } else {
            c.title = "Milestone: \(Fmt.num(m.lb, 0)) lb"
            var body = "Your first weigh-in at or under \(Fmt.num(m.lb, 0)) lb."
            if let toGo = p.toGo, let goal = p.goal { body += " \(Fmt.num(toGo, 1)) lb to \(Fmt.num(goal, 0))." }
            c.body = body
        }
        c.sound = .default
        c.userInfo = ["route": "progress"]
        let req = UNNotificationRequest(identifier: "log.progress.milestone.\(Int(m.lb))", content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }

    /// Next Sunday at 6 PM in the log's time zone (today, if it's Sunday before 6).
    static func nextRecap(after now: Date) -> Date {
        let cal = LogTime.calendar
        var start = cal.startOfDay(for: now)
        for _ in 0..<8 {
            if cal.component(.weekday, from: start) == 1,
               let at = cal.date(bySettingHour: 18, minute: 0, second: 0, of: start), at > now { return at }
            start = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        }
        return now.addingTimeInterval(7 * 86400)
    }

    static func recapText(_ p: WeightProgress.Summary) -> String {
        var parts: [String] = []
        let week = p.changes.first { $0.label == "1 week" }
        parts.append("Trend \(Fmt.num(p.current, 1)) lb" + (week.map { ", \(signed($0.delta)) lb this week" } ?? "") + ".")
        if p.done > 0 { parts.append("\(Fmt.num(p.done, 1)) lb down since you started.") }
        if let w = p.weekly { parts.append("Pace \(signed(w, 2)) lb a week.") }
        if let eta = p.goalETA, let goal = p.goal { parts.append("At this pace, \(Fmt.num(goal, 0)) around \(LogTime.shortDate(eta)).") }
        return parts.joined(separator: " ")
    }

    static func signed(_ v: Double, _ digits: Int = 1) -> String {
        let s = Fmt.num(abs(v), digits)
        return v > 0 ? "+" + s : v < 0 ? "−" + s : s
    }

    static func scheduleRecap(_ p: WeightProgress.Summary, now: Date) {
        let c = UNMutableNotificationContent()
        c.title = "Your week"
        c.body = recapText(p)
        c.sound = .default
        c.userInfo = ["route": "progress"]
        let wait = max(60, nextRecap(after: now).timeIntervalSince(now))
        let req = UNNotificationRequest(identifier: recapID, content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
}
