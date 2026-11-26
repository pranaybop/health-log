import SwiftUI
import LogCore

// Summary (renderTrendSummary + the weight card) and Weight (weight card, stall check, body
// composition) sections.

struct TrSummarySectionView: View {
    var m: TrSummaryModel
    var open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(Array(m.tiles.enumerated()), id: \.element.id) { i, t in
                    TrSummaryTileView(tile: t) { open(t.section) }
                        .gridCellColumns(m.tiles.count.isMultiple(of: 2) || i < m.tiles.count - 1 ? 1 : 2)
                }
            }
            .id("summary-tiles")
            TrWeightCard(m: m.weight).id("weight")
        }
    }
}

struct TrSummaryTileView: View {
    var tile: TrendsCalc.SummaryTile
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tile.label).font(.caption.weight(.semibold)).foregroundStyle(LogColor.ink2)
                Text(tile.value).font(.logNumber(26)).foregroundStyle(LogColor.ink).lineLimit(1).minimumScaleFactor(0.6)
                Text(tile.sub).font(.caption).foregroundStyle(LogColor.ink2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !tile.spark.isEmpty {
                    TrSparkline(points: tile.spark, from: tile.sparkFrom, to: tile.sparkTo)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(LogColor.surface, in: RoundedRectangle(cornerRadius: LogMetric.cardRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this section")
    }
}

struct TrWeightSectionView: View {
    var m: TrWeightSection
    var photos: [ProgressPhoto] = []

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            TrWeightCard(m: m.weight).id("weight")
            if let p = m.weight.progress { TrProgressCard(p: p).id("progress") }
            TrStallCard(s: m.stall).id("stall")
            TrBodyCompCard(b: m.body, now: m.weight.now).id("body-comp")
            ProgressPhotosCard(photos: photos).id("photos")
        }
    }
}

// MARK: - Weight card

struct TrWeightCard: View {
    var m: TrWeightModel
    @State var rangeID: String = "3m"
    @AppStorage("log.overlay") var overlayID: String = "none"

    var ranges: [TrRange] { TrRange.all }
    var range: TrRange { ranges.first { $0.id == rangeID } ?? ranges.first { $0.id == "3m" } ?? ranges[0] }
    var overlay: TrOverlay? { TrOverlay.all.first { $0.id == overlayID && $0.id != "none" } }

    var body: some View {
        if let last = m.sm.last, let first = m.sm.first {
            card(last: last, earliest: first.at)
        } else {
            LogCard("Weight") { EmptyNote("No weigh-ins yet. Log one on the Log tab.") }
        }
    }

    func start(_ r: TrRange, end: Date, earliest: Date) -> Date {
        switch r.id {
        case "glp1": return m.glp1
        case "all": return earliest
        default: return end.addingTimeInterval(-(r.days ?? 91) * 86400)
        }
    }

    func card(last: WeightPoint, earliest: Date) -> some View {
        let r = range
        let end = max(m.now, last.at)
        let startT = start(r, end: end, earliest: earliest)
        let inRange = m.sm.filter { $0.at >= startT }
        let first = inRange.first ?? m.sm[0]
        let change = last.trend - first.trend
        let lows = inRange.map(\.lb).min()
        let highs = inRange.map(\.lb).max()
        let withYear = r.id == "all" || r.id == "1y"
        // 1M / 3M / 1Y scroll back through every weigh-in; All and Since GLP-1 fit on screen.
        let scrolls = r.days != nil && earliest < startT
        let chartFrom = scrolls ? earliest : startT
        let drawn = scrolls ? m.sm : inRange

        // Straight-line projection from the post-dose trend, on the short ranges only.
        let proj = (r.id == "1m" || r.id == "3m") ? m.proj : nil
        var t1 = end
        var projPts: [TrendsCalc.Point] = []
        if let p = proj {
            let projEnd = last.at.addingTimeInterval(42 * 86400)
            t1 = projEnd
            var t = p.last.at
            while t <= projEnd {
                projPts.append(TrendsCalc.Point(at: t, value: p.value(at: t)))
                t = t.addingTimeInterval(86400)
            }
        }

        // The compare-with series, drawn as its own chart under the weight (one scale per chart).
        let ov = overlay
        let ovDaily: [String: Double] = ov.flatMap { m.overlays[$0.id] } ?? [:]
        let spanDays = end.timeIntervalSince(startT) / 86400
        let ovWeekly = r.id == "1y" || r.id == "all" || spanDays >= 180
        let ovPts: [TrendsCalc.OverlayPoint] = ov == nil ? [] : TrendsCalc.overlayPoints(ovDaily, weekly: ovWeekly).filter { $0.at >= startT && $0.at <= end }
        let avgWord = ovWeekly ? "weekly avg" : "7-day avg"

        var series: [TrSeries] = [
            TrSeries(id: "raw", kind: .dots, color: LogColor.s1, points: drawn.map { TrendsCalc.Point(at: $0.at, value: $0.lb) }, faint: true, radius: r.id == "all" ? 2 : 3),
            TrSeries(id: "trend", kind: .area, color: LogColor.s1, points: drawn.map { TrendsCalc.Point(at: $0.at, value: $0.trend) }, endDot: true),
        ]
        if proj != nil { series.append(TrSeries(id: "proj", kind: .line, color: LogColor.s1, points: projPts, dashed: true)) }
        var refs: [TrRef] = []
        if let goal = m.goal {
            refs.append(TrRef(value: goal, label: "Goal \(TrendsCalc.num(goal))", inDomain: r.id != "all" ? abs(goal - last.trend) < 30 : true))
        }
        var marks: [TrMark] = []
        if m.glp1 >= chartFrom { marks.append(TrMark(at: m.glp1, label: LogTime.journeyName)) }
        if m.reta >= chartFrom && m.reta <= t1 { marks.append(TrMark(at: m.reta, label: "Reta")) }

        let byTime = m.byTime
        let scrub: (TrendsCalc.Point, [String: TrendsCalc.Point]) -> TrScrub = { p, _ in
            guard let w = byTime[p.at] else { return ("\(TrendsCalc.num(p.value, 1)) lb", LogTime.weekdayDate(p.at)) }
            var extra = ""
            if let ov {
                if let v = ovDaily[w.day] {
                    extra = ", \(ov.text(v))"
                } else if let near = ovPts.min(by: { abs($0.at.timeIntervalSince(w.at)) < abs($1.at.timeIntervalSince(w.at)) }),
                          abs(near.at.timeIntervalSince(w.at)) <= 36 * 3600 {
                    extra = ", \(ov.text(near.value)) \(avgWord)"
                }
            }
            let year = withYear ? ", \(LogTime.calendar.component(.year, from: w.at))" : ""
            return ("\(TrendsCalc.num(w.lb, 1)) lb", "\(LogTime.weekdayDate(w.at))\(year), trend \(TrendsCalc.num(w.trend, 1))\(extra)")
        }
        let readout: TrScrub = ("\(TrendsCalc.num(last.trend, 1)) lb",
                                "Trend now. Last weigh-in \(TrendsCalc.num(last.lb, 1)) lb, \(LogTime.weekdayDate(last.at))")

        var legend: [TrLegendItem] = [
            TrLegendItem(key: .faintDot(LogColor.s1), label: "Weigh-ins"),
            TrLegendItem(key: .line(LogColor.s1), label: "Smoothed trend"),
        ]
        if proj != nil { legend.append(TrLegendItem(key: .dashed(LogColor.s1), label: "Straight-line projection")) }
        if m.goal != nil { legend.append(TrLegendItem(key: .ref, label: "Goal")) }

        var ovNote: String?
        if let ov {
            let logged = ovPts.reduce(0) { $0 + (ovWeekly ? $1.n : ($1.day != nil ? 1 : 0)) }
            let firstKey = ovDaily.keys.min()
            if ovPts.isEmpty {
                ovNote = ov.id == "calories" ? "No food logged in this range." : "No \(ov.label.lowercased()) data in this range."
            } else if ov.id == "calories" && logged < 7 {
                ovNote = "\(logged) day\(TrendsCalc.s(logged)) of food logged in this range, so the line fills in as you log."
            } else if let k = firstKey, LogTime.noon(k) > startT {
                ovNote = "\(ov.title) data starts \(TrendsCalc.short(k))."
            }
        }

        let pace = m.pace
        let stats = [
            TrendsCalc.Tile("Change, \(r.label)", "\(TrendsCalc.signed(change)) lb", "trend to trend"),
            TrendsCalc.Tile("Pace", pace.map { "\(TrendsCalc.signed($0.weekly)) lb/wk" } ?? "—",
                            pace.map { "\(TrendsCalc.num(abs($0.weekly / last.lb) * 100, 1))% of body weight" } ?? "last 4 weeks"),
            TrendsCalc.Tile("Range", lows.map { "\(TrendsCalc.num($0, 1))–\(TrendsCalc.num(highs, 1))" } ?? "—", "lowest to highest"),
        ]
        let caption = proj.map { p in
            "The trend smooths day-to-day water swings. The projection extends the straight-line fit since starting tirzepatide (\(TrendsCalc.signed(p.weekly, 2)) lb a week) six weeks out. It describes the past; it isn’t a prediction."
        } ?? "The trend smooths day-to-day water swings, so one high or low weigh-in barely moves it."

        return LogCard("Weight") {
            Picker("Range", selection: $rangeID) {
                ForEach(ranges) { x in Text(x.label).tag(x.id).accessibilityLabel(x.a11y) }
            }
            .pickerStyle(.segmented)
            .onAppear { if !ranges.contains(where: { $0.id == rangeID }) { rangeID = "3m" } }

            if inRange.count >= 2 {
                TrTimeChart(t0: chartFrom, t1: t1, series: series, refs: refs, marks: marks, height: 220, yTicks: 5,
                            snap: "trend", readout: readout, scrub: scrub, aria: "Weight, \(r.label) range",
                            scrollWindow: scrolls ? end.timeIntervalSince(startT) : nil,
                            scrollInitialEnd: end)
                    .id("weight-\(r.id)")
                if scrolls {
                    Caption("Swipe the chart sideways to go back in time. The scale fits what’s on screen.")
                }
            } else {
                TrReadout(main: readout.main, sub: readout.sub)
                EmptyNote("Only one weigh-in in this range. Try a longer range.")
            }
            TrLegend(items: legend)

            HStack(spacing: 8) {
                Text("Compare with").font(.subheadline).foregroundStyle(LogColor.ink2)
                Spacer(minLength: 8)
                Picker("Compare with", selection: $overlayID) {
                    ForEach(TrOverlay.all) { o in Text(o.id == "none" ? "Off" : o.title).tag(o.id) }
                }
                .pickerStyle(.menu)
                .tint(LogColor.link)
            }

            if let ov, !ovPts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    TrSubHead("\(ov.title), \(ovWeekly ? "weekly average" : "7-day average")", key: .line(TrColor.series(ov.color)))
                    TrTimeChart(t0: startT, t1: t1,
                                series: [TrSeries(id: "ov", kind: .line, color: TrColor.series(ov.color), points: ovPts.map { TrendsCalc.Point(at: $0.at, value: $0.value, key: $0.key) }, endDot: true)],
                                height: 110, yTicks: 3, yFloor: ov.zero ? 0 : nil, fmtY: { ov.axis($0) }, snap: "ov",
                                readout: (ov.text(ovPts[ovPts.count - 1].value), "Latest \(avgWord). Same dates as the weight chart."),
                                scrub: { p, _ in (ov.text(p.value), "\(ovWeekly ? "Week of \(TrendsCalc.short(p.key))" : LogTime.weekdayDate(p.at)), \(avgWord)") },
                                aria: "\(ov.title) under the weight chart")
                }
            }
            if let ovNote { Caption(ovNote) }

            TrTileGrid(tiles: stats, columns: 3, size: 17)

            if let loss = m.loss, loss.fast {
                TrWatchNote(title: "Losing \(TrendsCalc.num(loss.pct, 1))% of body weight a week",
                            text: "That’s above 1% a week over the last 4 weeks. Faster loss tends to take more muscle with it, so protein and strength work matter more right now.")
            }
            Caption(caption)
            TrDisclosure(title: "Recent weigh-ins", headers: ["Date", "Weight", "Trend"], rows: m.recent)
        }
    }
}

// MARK: - Goal progress and milestones

struct TrProgressCard: View {
    var p: WeightProgress.Summary

    /// "Mar 4", or "Mar 4, 2027" when it isn't this year.
    func date(_ d: Date) -> String {
        let y = LogTime.calendar.component(.year, from: d)
        return y == LogTime.calendar.component(.year, from: Date()) ? LogTime.shortDate(d) : "\(LogTime.shortDate(d)), \(y)"
    }

    var body: some View {
        LogCard("Progress") {
            if let goal = p.goal, let fraction = p.fraction {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(TrendsCalc.num(fraction * 100))% of the way to \(TrendsCalc.num(goal))")
                        .font(.logNumber(24)).foregroundStyle(LogColor.ink)
                    ProgressView(value: fraction)
                        .tint(LogColor.good)
                        .accessibilityLabel("Progress to goal")
                    HStack {
                        Text("Start \(TrendsCalc.num(p.start, 1))")
                        Spacer()
                        Text("Now \(TrendsCalc.num(p.current, 1))").fontWeight(.semibold)
                        Spacer()
                        Text("Goal \(TrendsCalc.num(goal, 1))")
                    }
                    .font(.caption).foregroundStyle(LogColor.ink2)
                }
            }
            TrTileGrid(tiles: tiles, columns: 2, size: 19)
            if !p.milestones.isEmpty {
                TrSubHead("Milestones")
                VStack(spacing: 0) {
                    ForEach(Array(p.milestones.enumerated()), id: \.element.id) { i, m in
                        if i > 0 { Divider().overlay(LogColor.hairline) }
                        milestoneRow(m)
                    }
                }
            }
            TrDisclosure(title: "Change over time", headers: ["Period", "Change", "Per week"], rows: p.changes.map { c in
                [c.label, "\(TrendsCalc.signed(c.delta)) lb", "\(TrendsCalc.signed(c.weekly, 2)) lb"]
            })
            Caption("All trend to trend, so one heavy or light morning doesn’t move these. Dates ahead assume the last 4 weeks’ pace keeps up; they shift as the trend does.")
        }
    }

    var tiles: [TrendsCalc.Tile] {
        var t: [TrendsCalc.Tile] = [
            TrendsCalc.Tile("Lost so far", "\(TrendsCalc.num(abs(p.done), 1)) lb", p.done >= 0 ? "since \(date(p.startDate))" : "above the start"),
        ]
        if let toGo = p.toGo { t.append(TrendsCalc.Tile("To go", "\(TrendsCalc.num(toGo, 1)) lb", p.goal.map { "to \(TrendsCalc.num($0))" })) }
        t.append(TrendsCalc.Tile("Pace", p.weekly.map { "\(TrendsCalc.signed($0, 2)) lb/wk" } ?? "—", "last 4 weeks, same as Weight"))
        if p.goal != nil {
            t.append(TrendsCalc.Tile("Goal date", p.goalETA.map { date($0) } ?? (p.toGo == 0 ? "Reached" : "—"),
                                     p.goalETA.map { "about \(weeksText($0)) at this pace" } ?? (p.toGo == 0 ? nil : "needs a steady pace toward it")))
        }
        if let shift = p.dayShift { t.append(TrendsCalc.Tile("Trend today", "\(TrendsCalc.signed(shift, 2)) lb", "vs a day earlier")) }
        if let low = p.lowest { t.append(TrendsCalc.Tile("Lowest trend", "\(TrendsCalc.num(low.trend, 1)) lb", date(low.at))) }
        return t
    }

    func weeksText(_ d: Date) -> String {
        let w = max(0, d.timeIntervalSinceNow / (7 * 86400))
        return w < 1.5 ? "\(TrendsCalc.num(w * 7)) days" : "\(TrendsCalc.num(w)) weeks"
    }

    func milestoneRow(_ m: WeightProgress.Milestone) -> some View {
        HStack(spacing: 10) {
            Image(systemName: m.reached != nil ? "checkmark.circle.fill" : (m.isGoal ? "flag.checkered" : "circle"))
                .foregroundStyle(m.reached != nil ? LogColor.good : LogColor.ink2)
            Text("\(TrendsCalc.num(m.lb)) lb\(m.isGoal ? " · goal" : "")")
                .font(.subheadline.weight(m.isGoal ? .semibold : .regular))
                .foregroundStyle(LogColor.ink)
            Spacer()
            Text(m.reached.map { "Reached \(date($0))" } ?? m.eta.map { "Around \(date($0))" } ?? "—")
                .font(.subheadline)
                .foregroundStyle(m.reached != nil ? LogColor.goodInk : LogColor.ink2)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

enum TrColor {
    static func series(_ id: String) -> Color {
        switch id {
        case "s2": return LogColor.s2
        case "s3": return LogColor.s3
        case "s4": return LogColor.s4
        default: return LogColor.s1
        }
    }
}

// MARK: - Stall check and body composition

struct TrStallCard: View {
    var s: TrendsCalc.Stall

    var body: some View {
        LogCard("Stall check") {
            if s.ready { TrLead(s.summary) } else { EmptyNote(s.summary) }
            if s.ready && !s.changed.isEmpty { TrReceipts(items: s.changed) }
            Caption("A description of what changed, not advice.")
        }
    }
}

struct TrBodyCompCard: View {
    var b: TrendsCalc.BodyComp
    var now: Date

    var body: some View {
        LogCard("Body composition") {
            if !b.tiles.isEmpty { TrTileGrid(tiles: b.tiles) }
            if b.lean.count >= 2, let first = b.lean.first, let last = b.lean.last {
                TrSubHead("Lean mass")
                TrTimeChart(t0: first.at, t1: max(now, last.at),
                            series: [
                                TrSeries(id: "l", kind: .line, color: LogColor.s4, points: b.lean, endDot: true),
                                TrSeries(id: "ld", kind: .dots, color: LogColor.s4, points: b.lean),
                            ],
                            height: 150, snap: "l",
                            readout: ("\(TrendsCalc.num(last.value, 1)) lb", "Lean mass, \(LogTime.weekdayDate(last.at))"),
                            scrub: { p, _ in ("\(TrendsCalc.num(p.value, 1)) lb", LogTime.weekdayDate(p.at)) },
                            aria: "Lean mass")
            }
            Caption(b.hasReadings
                    ? "Body fat comes from your scale through Apple Health; lean mass is that weigh-in minus its fat. Scale estimates swing day to day, so watch the direction over weeks."
                    : "Body fat and lean mass sync from Apple Health in the Log iPhone app (scales like RENPHO write them there). You can also add them under Measurement on the Log tab.")
        }
    }
}
