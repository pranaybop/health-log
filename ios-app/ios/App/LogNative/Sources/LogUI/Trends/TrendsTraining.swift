import SwiftUI
import LogCore

// Training section: running (renderRunning), steps (renderStepsCard), workouts (renderWorkouts).

struct TrTrainingSectionView: View {
    var m: TrTrainingModel

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            TrRunningCard(r: m.running).id("running")
            if let s = m.steps {
                LogCard("Steps") {
                    TrColumnChart(columns: s.days, color: LogColor.s4, height: 150,
                                  fmtY: { $0 >= 1000 ? "\(TrendsCalc.num($0 / 1000))K" : TrendsCalc.num($0) },
                                  main: "\(TrendsCalc.num(s.average)) a day", sub: "Average over \(s.count) days with data",
                                  scrub: { c in (c.value.map { "\(TrendsCalc.num($0)) steps" } ?? "No data", TrendsCalc.short(c.key)) },
                                  aria: "Steps, last 30 days")
                    Caption("From Apple Health imports, last 30 days.")
                }
                .id("steps")
            }
            if !m.workouts.isEmpty { TrWorkoutsCard(workouts: m.workouts, total: m.workoutCount).id("workouts") }
        }
    }
}

struct TrRunningCard: View {
    var r: TrendsCalc.Running

    var body: some View {
        LogCard("Running") {
            if r.raceDays > 0 { TrLead("Half marathon in \(r.raceDays) day\(TrendsCalc.s(r.raceDays)) (13.1 mi).") }
            TrColumnChart(columns: r.weeks, color: LogColor.s1, height: 140,
                          main: "\(TrendsCalc.num(r.thisWeek, 1)) mi this week",
                          sub: "Longest run in the last 4 weeks: \(TrendsCalc.num(r.longest4, 1)) mi",
                          scrub: { c in ("\(TrendsCalc.num(c.value, 1)) mi", r.details[c.key] ?? "Week of \(TrendsCalc.short(c.key))") },
                          aria: "Running miles a week, last 12 weeks")
            TrTable(headers: ["Week of", "Miles", "Longest", "Sleep", "Energy", "kcal"], rows: r.rows, compact: true)
            Caption("Runs from Apple Health. Sleep is the nightly average, energy comes from check-ins, kcal is the average on days with food logged.")
        }
    }
}

struct TrWorkoutsCard: View {
    var workouts: [Workout]
    var total: Int

    var body: some View {
        LogCard("Workouts") {
            TrLead("\(TrendsCalc.num(Double(total))) workouts imported from Apple Health. The latest \(min(8, workouts.count)):")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    head("When")
                    head("Activity")
                    head("Min").gridColumnAlignment(.trailing)
                    head("Avg HR").gridColumnAlignment(.trailing)
                }
                Divider().overlay(LogColor.hairline)
                ForEach(0..<workouts.count, id: \.self) { i in
                    row(workouts[i])
                }
            }
        }
    }

    func head(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(LogColor.ink2)
    }

    func row(_ w: Workout) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(w.startedDate.map { LogTime.weekdayDate($0) } ?? "—").font(.footnote).foregroundStyle(LogColor.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(TrendsCalc.capitalize(w.activity ?? "—")).font(.footnote).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
                if let mi = w.distanceMi { Text("\(TrendsCalc.num(mi, 2)) mi").font(.caption2).foregroundStyle(LogColor.ink2) }
            }
            Text(TrendsCalc.num(w.durationMin)).font(.logNumber(14, weight: .medium)).foregroundStyle(LogColor.ink)
            Text(w.avgHr.map { TrendsCalc.num($0) } ?? "—").font(.logNumber(14, weight: .medium)).foregroundStyle(LogColor.ink)
        }
    }
}
