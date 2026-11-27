import SwiftUI
import LogCore

struct TodayHero: View {
    let m: TodayModel

    var body: some View {
        Group {
            if m.points.isEmpty {
                EmptyNote("Log a weigh-in on the Log tab to start your journey.")
            } else if m.isToday {
                todayHero
            } else {
                pastHero
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: Today

    @ViewBuilder private var todayHero: some View {
        if let cur = m.points.last, let j = m.journey {
            let lost = j.startLb - cur.lb
            let total: Double? = j.goalLb.map { j.startLb - $0 }
            let pct: Double? = total.flatMap { $0 > 0 ? max(0, min(1, lost / $0)) : nil }
            VStack(alignment: .leading, spacing: 0) {
                HeroNumber(value: Fmt.num(cur.lb, 1), muted: false)
                Text("Weighed \(LogTime.weekdayDate(cur.at)), \(TodayText.timeCT(cur.at))")
                    .font(.subheadline).foregroundStyle(LogColor.ink2).padding(.top, 6)
                Wrap {
                    TodayChip(text: "\(Fmt.signed(-lost)) lb since start", tone: lost > 0 ? .good : lost < 0 ? .watch : .plain)
                    if let rp = m.pace {
                        let fast = Analytics.lossRate(m.points)?.fast ?? false
                        TodayChip(text: "\(Fmt.signed(rp.weekly)) lb a week (\(Fmt.num(abs(rp.weekly / cur.lb) * 100, 1))%)", tone: fast ? .watch : .plain)
                    }
                }
                .padding(.top, 12)
                if let pct, let total, let goal = j.goalLb {
                    CourseBar(share: pct, label: "\(Fmt.num(lost, 1)) of \(Fmt.num(total, 1)) pounds to goal",
                              start: Fmt.num(j.startLb, 1), middle: "\(Fmt.num(max(0, lost), 1)) of \(Fmt.num(total, 1)) lb, \(Int((pct * 100).rounded()))%",
                              goal: Fmt.num(goal, 0))
                        .padding(.top, 20)
                }
                if let pace = paceText(cur: cur, goal: j.goalLb) {
                    Text(pace).font(.subheadline).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Weight journey")
        }
    }

    private func paceText(cur: WeightPoint, goal: Double?) -> String? {
        guard let goal else { return nil }
        if cur.lb <= goal { return "You’re at or below your goal weight." }
        if let rp = m.pace, rp.weekly < -0.1 {
            let weeks = (rp.fittedNow - goal) / -rp.weekly
            let eta = m.now.addingTimeInterval(weeks * 7 * 86400)
            return "At your pace over the last 4 weeks of weigh-ins, \(Fmt.num(goal, 0)) lb lands around \(TodayText.weekdayDateYear(eta, now: m.now))."
        }
        if m.pace != nil { return "Your last 4 weeks of weigh-ins are flat, so there’s no arrival date yet." }
        return "A few more weigh-ins over the next week will show your pace."
    }

    // MARK: A past day

    @ViewBuilder private var pastHero: some View {
        let key = m.key
        let endOfDay = LogTime.noon(key).addingTimeInterval(12 * 3600)
        let onDay = m.points.filter { $0.day == key }
        let before = m.points.filter { $0.day < key }
        let trend = Analytics.trend(at: endOfDay, in: m.points)
        if onDay.isEmpty && trend == nil {
            EmptyNote("No weigh-ins yet by this day.")
        } else {
            let cur = onDay.last
            let shown = cur?.lb ?? trend ?? 0
            let prev = before.last
            let inJourney = LogTime.noon(key) >= LogTime.tirzStart && m.journey != nil
            let lost: Double? = inJourney ? (m.journey!.startLb - shown) : nil
            let total: Double? = inJourney ? m.journey!.goalLb.map { m.journey!.startLb - $0 } : nil
            let pct: Double? = (total != nil && total! > 0 && lost != nil) ? max(0, min(1, lost! / total!)) : nil
            VStack(alignment: .leading, spacing: 0) {
                HeroNumber(value: Fmt.num(shown, 1), muted: cur == nil)
                Text(metaLine(cur: cur, count: onDay.count))
                    .font(.subheadline).foregroundStyle(LogColor.ink2).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                Wrap {
                    if let cur, let prev {
                        TodayChip(text: "\(Fmt.signed(cur.lb - prev.lb)) lb vs \(LogTime.shortDate(prev.at))",
                                  tone: cur.lb < prev.lb ? .good : cur.lb > prev.lb ? .watch : .plain)
                    }
                    if cur != nil, let trend {
                        TodayChip(text: "Trend \(Fmt.num(trend, 1))")
                    }
                    if let lost {
                        TodayChip(text: "\(Fmt.signed(-lost)) lb since start", tone: lost > 0 ? .good : .plain)
                    }
                }
                .padding(.top, 12)
                if let pct, let lost, let total, let j = m.journey, let goal = j.goalLb {
                    CourseBar(share: pct, label: "\(Fmt.num(lost, 1)) of \(Fmt.num(total, 1)) pounds to goal by this day",
                              start: Fmt.num(j.startLb, 1), middle: "\(Int((pct * 100).rounded()))% by this day", goal: Fmt.num(goal, 0))
                        .padding(.top, 20)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Weight that day")
        }
    }

    private func metaLine(cur: WeightPoint?, count: Int) -> String {
        guard let cur else { return "No weigh-in this day. Showing the smoothed trend." }
        return "Weighed \(TodayText.timeCT(cur.at))\(count > 1 ? ", \(count) weigh-ins that day" : "")"
    }
}

/// "238.6 lb" in the hero's big rounded figures.
private struct HeroNumber: View {
    let value: String
    let muted: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 64

    init(value: String, muted: Bool) {
        self.value = value
        self.muted = muted
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.logNumber(min(size, 88), weight: .semibold)).tracking(-1.5)
                .foregroundStyle(muted ? LogColor.ink2 : LogColor.ink)
            Text("lb").font(.logNumber(min(size, 88) * 0.34, weight: .semibold)).foregroundStyle(LogColor.ink2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .combine)
    }
}

private struct CourseBar: View {
    let share: Double
    let label: String
    let start: String
    let middle: String
    let goal: String

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let x = max(0, min(1, share)) * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(LogColor.surface).frame(height: 12)
                    Capsule().fill(LogColor.s1).frame(width: x, height: 12)
                    Circle()
                        .fill(LogColor.surface)
                        .overlay(Circle().strokeBorder(LogColor.s1, lineWidth: 5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(LogColor.bg).padding(-3))
                        .offset(x: min(max(0, x - 11), geo.size.width - 22))
                }
                .frame(height: 22)
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                end(start, "start")
                Text(middle).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                end(goal, "goal")
            }
            .font(.footnote)
            .foregroundStyle(LogColor.ink2)
        }
    }

    private func end(_ value: String, _ word: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.logNumber(15, weight: .semibold)).foregroundStyle(LogColor.ink)
            Text(word)
        }
        .fixedSize()
    }
}
