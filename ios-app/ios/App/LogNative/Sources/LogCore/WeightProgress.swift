import Foundation

/// Goal progress the way weight-trend apps show it: how far from start to goal, when the goal
/// lands at the current pace, 5 lb milestones with the day each was reached (or should be), and
/// the trend's change over the usual periods. Everything is trend to trend, never raw weigh-ins.
public enum WeightProgress {
    public struct Milestone: Hashable, Sendable, Identifiable {
        public var lb: Double
        public var reached: Date?
        /// Expected date at the current pace, for milestones not reached yet.
        public var eta: Date?
        public var isGoal: Bool
        public var id: Double { lb }
    }

    public struct Change: Hashable, Sendable, Identifiable {
        public var label: String
        public var days: Double?
        public var delta: Double
        /// Average change per week over the period.
        public var weekly: Double
        public var id: String { label }
    }

    public struct Summary: Hashable, Sendable {
        public var start: Double
        public var current: Double
        public var goal: Double?
        public var startDate: Date
        /// Toward the goal so far (positive = progress, whichever way the goal is).
        public var done: Double
        public var toGo: Double?
        /// 0...1 of the way from start to goal.
        public var fraction: Double?
        /// lb a week over the last 4 weeks, as the Weight card shows it (negative = losing).
        public var weekly: Double?
        public var goalETA: Date?
        public var milestones: [Milestone]
        public var changes: [Change]
        public var lowest: WeightPoint?
        /// Trend change since the trend a day earlier.
        public var dayShift: Double?
    }

    /// Weigh-ins from the start of this run: the last one up to two weeks before `since` (so the
    /// starting weigh-in counts), else the first one after it. Apple Health backfill can bring in
    /// years-old weigh-ins; without this, milestones and the lowest trend came from those.
    public static func run(_ sm: [WeightPoint], since: Date?) -> [WeightPoint] {
        guard let since else { return sm }
        if let i = sm.lastIndex(where: { $0.at <= since }), since.timeIntervalSince(sm[i].at) <= 14 * 86400 {
            return Array(sm[i...])
        }
        return sm.filter { $0.at > since }
    }

    /// `startLb` is the profile's starting weight (falls back to the first trend). `since` is when
    /// this run started (the first GLP-1 shot); older weigh-ins are left out.
    public static func make(_ all: [WeightPoint], startLb: Double?, goalLb: Double?, since: Date? = nil, now: Date, step: Double = 5) -> Summary? {
        let sm = run(all, since: since)
        guard let first = sm.first, let last = sm.last else { return nil }
        let start = startLb ?? first.trend
        let current = last.trend
        let dir: Double = (goalLb ?? (start - 1)) < start ? -1 : 1 // -1 = losing toward the goal
        let done = (current - start) * dir
        let toGo = goalLb.map { max(0, ($0 - current) * dir) }
        var fraction: Double?
        if let g = goalLb, abs(g - start) > 0.01 { fraction = min(1, max(0, done / abs(g - start))) }
        // The Weight card's pace (a line through the last 4 weeks of weigh-ins, or as many
        // as this run has), so both cards agree; else the trend's change over what there is.
        let span = last.at.timeIntervalSince(first.at) / 86400
        let weekly = Analytics.Trends.recentPace(sm, days: 28)?.weekly
            ?? (span >= 7 ? Analytics.trendRate(sm, days: min(28, span)) : nil)
        let towardPerWeek = weekly.map { $0 * dir } ?? 0

        func eta(_ target: Double) -> Date? {
            guard towardPerWeek > 0.05 else { return nil }
            let left = (target - current) * dir
            guard left > 0 else { return nil }
            return last.at.addingTimeInterval(left / towardPerWeek * 7 * 86400)
        }

        // Milestones: every `step` lb from the first round number past the start, then the goal.
        var milestones: [Milestone] = []
        if let g = goalLb {
            var m = dir < 0 ? (start / step).rounded(.down) * step : (start / step).rounded(.up) * step
            if abs(m - start) < 0.01 { m += dir * step }
            var guardCount = 0
            while (m - g) * dir < -0.01 && guardCount < 200 {
                milestones.append(milestone(m, sm: sm, dir: dir, eta: eta(m), isGoal: false))
                m += dir * step
                guardCount += 1
            }
            milestones.append(milestone(g, sm: sm, dir: dir, eta: eta(g), isGoal: true))
        }

        var changes: [Change] = []
        for (label, days) in [("1 week", 7.0), ("2 weeks", 14), ("1 month", 30), ("3 months", 91), ("6 months", 182), ("1 year", 365)] {
            let from = last.at.addingTimeInterval(-days * 86400)
            guard first.at <= from, let then = Analytics.trend(at: from, in: sm) else { continue }
            changes.append(Change(label: label, days: days, delta: current - then, weekly: (current - then) / days * 7))
        }
        let allDays = max(1, last.at.timeIntervalSince(first.at) / 86400)
        changes.append(Change(label: "Since start", days: nil, delta: current - first.trend, weekly: (current - first.trend) / allDays * 7))

        let lowest = dir < 0 ? sm.min { $0.trend < $1.trend } : sm.max { $0.trend < $1.trend }
        let dayShift = Analytics.trend(at: last.at.addingTimeInterval(-86400), in: sm).map { current - $0 }

        return Summary(start: start, current: current, goal: goalLb, startDate: first.at, done: done, toGo: toGo,
                       fraction: fraction, weekly: weekly, goalETA: goalLb.flatMap { eta($0) },
                       milestones: milestones, changes: changes, lowest: lowest, dayShift: dayShift)
    }

    static func milestone(_ lb: Double, sm: [WeightPoint], dir: Double, eta: Date?, isGoal: Bool) -> Milestone {
        let hit = sm.first { ($0.trend - lb) * dir >= 0 }
        return Milestone(lb: lb, reached: hit?.at, eta: hit == nil ? eta : nil, isGoal: isGoal)
    }
}
