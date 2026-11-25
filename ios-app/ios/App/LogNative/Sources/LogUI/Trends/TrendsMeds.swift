import SwiftUI
import LogCore

// Meds section: the week after a shot, appetite by drug level, retatrutide vs tirzepatide, cycle
// recaps, feel report, wear-off, long-run timing and side effects.

struct TrMedsSectionView: View {
    var m: TrMedsModel

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            if let rows = m.shotWeek { TrShotWeekCard(rows: rows).id("shot-week") }
            if let a = m.appetite { TrAppetiteCard(a: a).id("appetite") }
            TrRetaCard(r: m.reta).id("reta-vs-tirz")
            TrCyclesCard(recaps: m.recaps).id("cycles")
            TrFeelCard(f: m.feel).id("feel")
            LogCard("Wear-off") {
                if m.wearOff.ready { TrLead(m.wearOff.summary) } else { EmptyNote(m.wearOff.summary) }
                if m.wearOff.ready && !m.wearOff.details.isEmpty { TrReceipts(items: m.wearOff.details) }
            }
            .id("wear-off")
            TrLongRunCard(r: m.longRun).id("long-run")
            TrSideEffectsCard(effects: m.effects).id("side-effects")
        }
    }
}

/// A shaded cell of a by-day grid (the web's sw-cell).
struct TrHeatCell: View {
    var text: String
    var alpha: Double?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LogColor.surface2)
            if let alpha {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LogColor.s3.opacity(alpha))
            }
            Text(text)
                .font(.logNumber(13, weight: alpha == nil ? .regular : .semibold))
                .foregroundStyle(alpha == nil ? LogColor.ink2 : LogColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }
}

struct TrDayCell {
    var text: String
    var alpha: Double?
}

struct TrDayRow {
    var label: String
    var cells: [TrDayCell]
}

/// Rows of seven day cells under a D0-D6 style header.
struct TrDayGrid: View {
    var header: [String]
    var rows: [TrDayRow]

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(0..<header.count, id: \.self) { i in
                    Text(header[i]).font(.caption2.weight(.semibold)).foregroundStyle(LogColor.ink2).frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<rows.count, id: \.self) { r in
                GridRow {
                    Text(rows[r].label).font(.caption).foregroundStyle(LogColor.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(width: 74, alignment: .leading)
                    ForEach(0..<rows[r].cells.count, id: \.self) { i in
                        TrHeatCell(text: rows[r].cells[i].text, alpha: rows[r].cells[i].alpha)
                    }
                }
            }
        }
    }
}

struct TrShotWeekCard: View {
    var rows: [TrendsCalc.WeekRow]

    var body: some View {
        let any = rows.contains { $0.counts.contains { $0 > 0 } }
        let grid: [TrDayRow] = rows.map { r in
            let mx = max(r.averages.compactMap { $0 }.max() ?? 0, 0.0001)
            let cells: [TrDayCell] = r.averages.map { v in
                guard let v else { return TrDayCell(text: "·", alpha: nil) }
                let digits = v < 10 && v.truncatingRemainder(dividingBy: 1) != 0 ? 1 : 0
                return TrDayCell(text: TrendsCalc.num(v, digits), alpha: 0.12 + 0.6 * (v / mx))
            }
            return TrDayRow(label: r.label, cells: cells)
        }
        let table: [[String]] = rows.map { r in
            [r.label] + (0..<7).map { i in r.counts[i] > 0 ? "\(TrendsCalc.num(r.averages[i], 1)) (\(r.counts[i]))" : "—" }
        }
        return LogCard("The week after a shot") {
            if any {
                Caption("Average by day since your shot. Darker means higher within the row. Side effects use the worst one that day.")
                TrDayGrid(header: ["Shot", "+1", "+2", "+3", "+4", "+5", "+6"], rows: grid)
                    .accessibilityLabel("Averages by day since shot")
                TrDisclosure(title: "The week after a shot", headers: ["", "Shot day", "Day 1", "Day 2", "Day 3", "Day 4", "Day 5", "Day 6"],
                             rows: table, scrolls: true)
            } else {
                EmptyNote("Fills in as you check in, tap food thoughts and log side effects.")
            }
        }
    }
}

struct TrAppetiteCard: View {
    var a: TrendsCalc.Appetite

    var body: some View {
        let bins = TrendsCalc.levelBins
        let maxPerDay = max(1, a.thoughts.compactMap { $0.perDay }.max() ?? 0)
        return LogCard("Appetite by drug level") {
            TrLead(a.lead)
            if let share = a.nowShare {
                Caption("Right now: \(TrendsCalc.num(share * 100))% of peak (\(bins[TrendsCalc.binOf(share)].label.lowercased())).")
            }
            TrSubHead("Food noise in check-ins, out of 10")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(0..<bins.count, id: \.self) { i in
                    barRow(bins[i], fraction: (a.noise[i].avg ?? 0) / 10, color: LogColor.s1,
                           value: a.noise[i].avg.map { TrendsCalc.num($0, 1) } ?? "—", sub: "\(a.noise[i].n) day\(TrendsCalc.s(a.noise[i].n))")
                }
            }
            TrSubHead("Food thoughts a day")
            if a.trackedDays >= 3 {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(0..<bins.count, id: \.self) { i in
                        barRow(bins[i], fraction: (a.thoughts[i].perDay ?? 0) / maxPerDay, color: LogColor.s2,
                               value: a.thoughts[i].perDay.map { TrendsCalc.num($0, 1) } ?? "—", sub: "\(a.thoughts[i].n) logged")
                    }
                }
            } else {
                Caption("Shows once you've tracked food thoughts for 3 days. Tap a food-thought button on Today when one hits.")
            }
            Caption("Level is the modeled amount of the medication you're on, as a share of the peak a weekly dose at your latest amount settles at (half-life 5 days for tirzepatide, 6 for retatrutide), so it reads the same across dose changes and the switch. Food thoughts are divided by the hours you spent in each band. A dash means no data in that band yet.")
        }
    }

    func barRow(_ bin: TrendsCalc.LevelBin, fraction: Double, color: Color, value: String, sub: String) -> some View {
        GridRow(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bin.label).font(.subheadline.weight(.medium)).foregroundStyle(LogColor.ink)
                Text(bin.sub).font(.caption2).foregroundStyle(LogColor.ink2)
            }
            TrMeter(fraction: fraction, color: color)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.logNumber(15)).foregroundStyle(LogColor.ink)
                Text(sub).font(.caption2).foregroundStyle(LogColor.ink2)
            }
            .gridColumnAlignment(.trailing)
        }
    }
}

struct TrRetaCard: View {
    var r: TrendsCalc.RetaVsTirz

    var body: some View {
        typealias W = TrendsCalc.WindowStats
        let lines: [(String, KeyPath<W, Double?>, (Double) -> String)] = [
            ("Weight change", \W.delta, { "\(TrendsCalc.signed($0)) lb" }),
            ("Food noise", \W.noise, { "\(TrendsCalc.num($0, 1)) /10" }),
            ("Energy", \W.energy, { "\(TrendsCalc.num($0, 1)) /10" }),
            ("Side effects", \W.effectAvg, { "\(TrendsCalc.num($0, 1)) /10" }),
            ("Resting heart rate", \W.rhr, { "\(TrendsCalc.num($0)) bpm" }),
            ("HRV", \W.hrv, { "\(TrendsCalc.num($0)) ms" }),
            ("Burned a day", \W.burn, { "\(TrendsCalc.num($0)) kcal" }),
            ("Sleep", \W.sleep, { "\(TrendsCalc.num($0, 1)) h" }),
        ]
        let rows: [[String]] = lines.map { line in
            let a = r.tirz[keyPath: line.1].map(line.2) ?? "—"
            var b = ""
            if let reta = r.reta { b = reta[keyPath: line.1].map(line.2) ?? "—" }
            return [line.0, a, b]
        }
        return LogCard("Retatrutide vs tirzepatide") {
            TrLead(r.lead)
            TrTable(headers: ["", "Tirzepatide", r.reta == nil ? "" : "Retatrutide"], rows: rows)
            Caption("Averages over each window; calories burned is the Apple Watch's middle full day. Dashes mean that measure wasn’t logged in the window. The retatrutide column fills in over the first two weeks. This is a comparison, not advice.")
        }
    }
}

struct TrCyclesCard: View {
    var recaps: [TrendsCalc.CycleRecap]

    static let vs = ["less": "Less", "usual": "Usual", "more": "More"]
    static let feel = ["strong": "Strong", "fading": "Fading", "not_feeling_it": "Not feeling it"]

    var body: some View {
        LogCard("Cycle recaps") {
            if recaps.isEmpty {
                EmptyNote("Needs logged doses to split cycles.")
            } else {
                ForEach(Array(recaps.reversed())) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        if c.id != recaps.last?.id { Divider().overlay(LogColor.hairline).padding(.bottom, 6) }
                        HStack(spacing: 8) {
                            Text("Cycle \(c.cycle.index), \(TrendsCalc.num(c.cycle.startMg, 1)) mg").font(.headline).foregroundStyle(LogColor.ink)
                            if c.cycle.open { TrBadge("Current", tone: .good) }
                        }
                        Text("\(LogTime.shortDate(c.cycle.startAt)) to \(c.cycle.open ? "now" : TrendsCalc.short(c.cycle.endDay))")
                            .font(.footnote).foregroundStyle(LogColor.ink2)
                        TrProps(rows: rows(c))
                    }
                }
            }
        }
    }

    func label(_ map: [String: String], _ v: String) -> String { map[v] ?? TrendsCalc.capitalize(v) }

    func rows(_ c: TrendsCalc.CycleRecap) -> [(String, String)] {
        var out: [(String, String)] = [
            ("Weight", c.delta.map { "\(TrendsCalc.signed($0)) lb" } ?? "Needs weigh-ins in this cycle"),
            ("Eating", c.ate.map { label(Self.vs, $0) } ?? "Needs ate-vs-usual check-ins"),
            ("Movement", c.moved.map { label(Self.vs, $0) } ?? c.steps.map { "Avg \(TrendsCalc.num($0)) steps" } ?? "Needs movement check-ins"),
            ("Feel", c.feel.map { label(Self.feel, $0) } ?? c.foodNoise.map { "Avg food noise \(TrendsCalc.num($0, 1))" } ?? "Needs feel tags"),
        ]
        if let v = c.vsPrevWeight { out.append(("vs previous", "\(TrendsCalc.signed(v)) lb")) }
        return out
    }
}

struct TrFeelCard: View {
    var f: TrendsCalc.FeelReport

    var body: some View {
        LogCard("Feel report") {
            if f.ready {
                TrTileGrid(tiles: [
                    tile("Mood", f.mood), tile("Energy", f.energy), tile("Food noise", f.foodNoise), tile("Sleep quality", f.sleepQuality),
                ])
                Caption("Averages across \(f.count) scored days, on a 1–10 scale.")
            } else {
                EmptyNote(f.summary)
            }
        }
    }

    func tile(_ label: String, _ v: TrendsCalc.MeanN?) -> TrendsCalc.Tile {
        TrendsCalc.Tile(label, v.map { TrendsCalc.num($0.mean, 1) } ?? "—", v.map { "\($0.n) days" })
    }
}

struct TrLongRunCard: View {
    var r: TrendsCalc.LongRun

    var body: some View {
        LogCard("Long-run timing") {
            if !r.hasDoses {
                EmptyNote("Needs a logged shot before runs, energy and HRV can be lined up with days since the dose.")
            } else if !r.hasData {
                EmptyNote("No energy, HRV or runs have been logged against a shot week yet.")
            } else {
                Caption("Averages by day since the shot (0 is shot day). Energy is from check-ins, HRV from Apple Health, miles from runs.")
                TrDayGrid(header: (0...6).map { "D\($0)" }, rows: [
                    TrDayRow(label: "Energy", cells: cells(r.energy, 1)),
                    TrDayRow(label: "HRV, ms", cells: cells(r.hrv, 0)),
                    TrDayRow(label: "Run, mi", cells: cells(r.miles, 1)),
                ])
                TrLead(r.takeaway)
            }
        }
    }

    func cells(_ values: [Double?], _ digits: Int) -> [TrDayCell] {
        values.map { v in
            guard let v else { return TrDayCell(text: "—", alpha: nil) }
            return TrDayCell(text: TrendsCalc.num(v, digits), alpha: 0.35)
        }
    }
}

struct TrSideEffectsCard: View {
    var effects: [SideEffect]

    var body: some View {
        LogCard("Side effects") {
            if effects.isEmpty {
                EmptyNote("No side effects logged yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(0..<effects.count, id: \.self) { i in
                        if i > 0 { Divider().overlay(LogColor.hairline) }
                        row(effects[i])
                    }
                }
            }
        }
    }

    func row(_ e: SideEffect) -> some View {
        let sev = e.severity ?? 0
        let tone: TrTone = sev >= 7 ? .crit : sev >= 4 ? .watch : .steady
        let sub = [TrendsCalc.short(e.recordedOn), e.notes ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
        let sevText = TrendsCalc.num(sev, sev.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.effect ?? "—").font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink)
                Text(sub).font(.footnote).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(sevText).font(.logNumber(15))
                Text("/10").font(.caption2.weight(.semibold)).opacity(0.75)
            }
            .foregroundStyle(TrBadge.ink(tone))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(TrBadge.soft(tone), in: Capsule())
            .accessibilityLabel("Severity \(sevText) of 10")
        }
        .padding(.vertical, 10)
    }
}
