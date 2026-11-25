import SwiftUI
import LogCore

// Food section: calories and protein (renderFoodTrends), maintenance calories
// (renderMaintenance), protein target (renderProteinCard), food thoughts (renderFoodThoughtsCard).

struct TrFoodSectionView: View {
    var m: TrFoodModel

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            TrFoodTrendsCard(f: m.trends).id("food-trends")
            if !m.maintenance.burn.isEmpty || !m.maintenance.logged.isEmpty {
                TrMaintenanceCard(m: m.maintenance, target: m.calorieTarget).id("maintenance")
            }
            if let p = m.protein {
                LogCard("Protein target") {
                    TrTileGrid(tiles: p.tiles)
                    Caption("Only days with food logged count, so a missing day doesn't drag the average down.")
                }
                .id("protein")
            }
            TrThoughtsCard(t: m.thoughts).id("food-thoughts")
        }
    }
}

struct TrFoodTrendsCard: View {
    var f: TrendsCalc.FoodTrends

    var body: some View {
        LogCard("Calories and protein") {
            if f.logged.isEmpty {
                EmptyNote("No food logged in the last 30 days.")
            } else if let cal = f.calories, let pro = f.protein {
                sub(cal, color: LogColor.s1)
                sub(pro, color: LogColor.s2)
                TrDisclosure(title: "Daily totals", headers: ["Day", "kcal", "Protein"], rows: f.logged.reversed().map { k in
                    [TrendsCalc.short(k), TrendsCalc.num(f.rows[k]?.calories), "\(TrendsCalc.num(f.rows[k]?.proteinG)) g"]
                })
            } else {
                TrLead("\(f.logged.count) day\(TrendsCalc.s(f.logged.count)) logged in the last 30. The daily charts appear once 3 days are in.")
                TrProps(rows: f.logged.map { k in
                    (TrendsCalc.short(k), "\(TrendsCalc.num(f.rows[k]?.calories)) kcal, \(TrendsCalc.num(f.rows[k]?.proteinG)) g protein")
                })
            }
        }
    }

    func sub(_ s: TrendsCalc.FoodSeries, color: Color) -> some View {
        let unit = s.unit
        return VStack(alignment: .leading, spacing: 6) {
            TrSubHead(s.title, key: .rect(color))
            TrColumnChart(columns: s.days, color: color, target: s.target, targetLabel: s.target.map { "Target \(TrendsCalc.num($0))" },
                          height: 140, main: "\(TrendsCalc.num(s.average)) \(unit) average", sub: s.readoutSub,
                          scrub: { c in (c.value.map { "\(TrendsCalc.num($0)) \(unit)" } ?? "Not logged", TrendsCalc.short(c.key)) },
                          aria: "\(s.title), last 30 days")
        }
    }
}

struct TrMaintenanceCard: View {
    var m: TrendsCalc.Maintenance
    var target: Double?

    var body: some View {
        let best = m.best
        let main = best.map { "About \(TrendsCalc.num(($0 / 10).rounded() * 10)) kcal a day" } ?? "Not enough data yet"
        let sub = m.fromLogs != nil ? "From your food logs and weight trend, last 4 full weeks"
            : m.watch != nil ? "Apple Watch, burned per day over the last 4 full weeks"
            : "Needs a week of Apple Watch days or two weeks of food logs"
        var series: [TrSeries] = []
        if !m.burn.isEmpty {
            series.append(TrSeries(id: "burn", kind: .dots, color: LogColor.s1, points: m.burn, faint: true, radius: 2.5))
            if m.burn.count > 2 {
                series.append(TrSeries(id: "burnS", kind: .smooth, color: LogColor.s1, points: TrendsCalc.rolling(m.burn, days: 7), endDot: true))
            }
        }
        if !m.logged.isEmpty { series.append(TrSeries(id: "eat", kind: .dots, color: LogColor.s2, points: m.logged, radius: 3.5)) }
        var burnMap: [String: Double] = [:]
        for p in m.burn { burnMap[p.key] = p.value }
        var eatMap: [String: Double] = [:]
        for p in m.logged { eatMap[p.key] = p.value }
        let refs: [TrRef] = target.map { [TrRef(value: $0, label: "Target \(TrendsCalc.num($0))")] } ?? []
        var legend: [TrLegendItem] = []
        if !m.burn.isEmpty { legend.append(TrLegendItem(key: .line(LogColor.s1), label: "Burned, Apple Watch (7-day average)")) }
        if !m.logged.isEmpty { legend.append(TrLegendItem(key: .dot(LogColor.s2), label: "Food logged")) }
        if target != nil { legend.append(TrLegendItem(key: .ref, label: "Calorie target")) }
        var rows: [(String, String)] = [
            ("Apple Watch says", m.watch.map { "\(TrendsCalc.num($0)) kcal a day (\(m.burn.count) days)" } ?? "Needs 7 full days (\(m.burn.count) so far)"),
            ("Food logs and weight say", m.fromLogs.map { "\(TrendsCalc.num($0)) kcal a day" } ?? "Needs 14 logged days in the 4 weeks (\(m.logged.count) so far)"),
        ]
        if !m.logged.isEmpty { rows.append(("You ate", "\(TrendsCalc.num(m.intake)) kcal a day on average (\(m.logged.count) logged days)")) }
        if let rate = m.rate { rows.append(("Weight trend", "\(TrendsCalc.signed(rate, 1)) lb a week")) }
        if let target, let watch = m.watch {
            let under = watch - target
            rows.append(("Eating \(TrendsCalc.num(target))", under > 0
                ? "\(TrendsCalc.num(under)) kcal under the watch, about \(TrendsCalc.num(under * 7 / TrendsCalc.kcalPerLb, 1)) lb a week if it's right"
                : "\(TrendsCalc.num(-under)) kcal over the watch's estimate"))
        }
        let t0 = LogTime.noon(m.start).addingTimeInterval(-12 * 3600)
        let t1 = LogTime.noon(m.end).addingTimeInterval(12 * 3600)
        let snapID = m.burn.isEmpty ? "eat" : "burn"
        return LogCard("Maintenance calories") {
            if series.isEmpty {
                TrReadout(main: main, sub: sub)
            } else {
                TrTimeChart(t0: t0, t1: t1, series: series, refs: refs, height: 170, snap: snapID, readout: (main, sub),
                            scrub: { p, _ in
                                let b = burnMap[p.key]
                                let e = eatMap[p.key]
                                return (b.map { "\(TrendsCalc.num($0)) kcal burned" } ?? "Watch day skipped",
                                        "\(TrendsCalc.short(p.key))\(e.map { ". Ate \(TrendsCalc.num($0)) kcal" } ?? "")")
                            },
                            aria: "Calories burned and eaten, last 4 full weeks")
                TrLegend(items: legend)
            }
            TrProps(rows: rows)
            Caption("From logs: average calories logged plus 3,500 kcal for every pound the weight trend dropped, over the last 4 full weeks. Only days with at least 800 kcal logged count, since a half-logged day would pull it down. The watch figure is total burned (active plus resting), skipping days it was barely worn, and uses the middle day so one odd reading doesn't skew it. Watch estimates can be off by a few hundred calories either way.")
        }
    }
}

struct TrThoughtsCard: View {
    var t: TrendsCalc.ThoughtsCard?

    var body: some View {
        LogCard("Food thoughts") {
            if let t {
                let main = "\(TrendsCalc.num(t.perDay, 1)) a day"
                let sub = "\(t.total) since \(TrendsCalc.short(t.firstKey))"
                if t.days.count >= 2 {
                    TrColumnChart(columns: t.days, color: LogColor.s2, height: 130, main: main, sub: sub,
                                  scrub: { c in
                                      let n = Int(c.value ?? 0)
                                      return ("\(n) food thought\(TrendsCalc.s(n))", TrendsCalc.short(c.key))
                                  },
                                  aria: "Food thoughts a day")
                } else {
                    TrReadout(main: main, sub: sub)
                }
                TrProps(rows: [("Most often around", t.peakLabel), ("Strong pull or craving", "\(t.strong) of \(t.count)")])
            } else {
                EmptyNote("Tap a button under Thinking about food? on Today when it happens. Patterns show up here.")
            }
        }
    }
}
