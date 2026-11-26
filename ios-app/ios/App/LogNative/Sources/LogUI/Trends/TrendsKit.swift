import SwiftUI
import Charts
import LogCore

// Shared pieces for the Trends tab: the readout line above each chart, time / column / scatter
// charts with tap-and-drag selection, sparklines, legends, tables and small labels. Chart rules
// follow ios-app/www/charts.js: nice y ticks with 8% padding, calendar-aligned date ticks, dashed
// reference lines, thin vertical markers, one y-axis per chart.

typealias TrendsCalc = Analytics.Trends

// MARK: - Scales

/// niceTicks from charts.js: round steps (1, 2, 2.5, 5, 10 × 10^n) covering lo...hi.
struct TrNiceScale {
    var ticks: [Double]
    var lo: Double
    var hi: Double

    init(_ low: Double, _ high: Double, count: Int) {
        var lo0 = low
        var hi0 = high
        if !(hi0 - lo0 > max(abs(lo0), abs(hi0)) * 1e-9) {
            let mid = (lo0 + hi0) / 2
            hi0 = mid + 1
            lo0 = mid - 1
        }
        let raw = (hi0 - lo0) / Double(max(1, count))
        let mag = pow(10, (log10(raw)).rounded(.down))
        let n = raw / mag
        let unit: Double = n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10
        let step = unit * mag
        let start = (lo0 / step).rounded(.down) * step
        let end = (hi0 / step).rounded(.up) * step
        var out: [Double] = []
        var v = start
        while v <= end + step / 2 && out.count < 50 {
            out.append((v * 1e6).rounded() / 1e6)
            v += step
        }
        ticks = out
        lo = start
        hi = max(end, start + step)
    }

    var visibleTicks: [Double] { ticks.filter { $0 >= lo - 1e-9 && $0 <= hi + 1e-9 } }
}

/// timeTicks from charts.js: weeks start Monday, months on the 1st, years on Jan 1.
struct TrTimeTicks {
    var dates: [Date] = []
    var labels: [Date: String] = [:]

    init(_ t0: Date, _ t1: Date, width: CGFloat = 300) {
        let spanDays = t1.timeIntervalSince(t0) / 86400
        let maxTicks = max(2.0, (Double(width) / 56).rounded(.down))
        let units: [(kind: String, n: Int, days: Double)] = [
            ("day", 1, 1), ("day", 2, 2), ("week", 1, 7), ("week", 2, 14), ("month", 1, 30.4), ("month", 3, 91),
            ("month", 6, 182), ("year", 1, 365), ("year", 2, 730),
        ]
        let unit = units.first { spanDays / $0.days <= maxTicks } ?? units[units.count - 1]
        let startKey = LogTime.dayKey(t0)
        let parts = startKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return }
        var found: [(Date, String)] = []
        if unit.kind == "day" || unit.kind == "week" {
            var key = startKey
            if unit.kind == "week" { while LogTime.monday(key) != key { key = LogTime.shift(key, 1) } }
            while LogTime.noon(key) <= t1 && found.count < 60 {
                let t = LogTime.noon(key)
                if t >= t0 { found.append((t, LogTime.shortDate(key: key))) }
                key = LogTime.shift(key, unit.kind == "week" ? 7 * unit.n : unit.n)
            }
        } else if unit.kind == "month" {
            var y = parts[0]
            var m = parts[1] + 1
            if m > 12 { m = 1; y += 1 }
            while (m - 1) % unit.n != 0 { m += 1; if m > 12 { m = 1; y += 1 } }
            let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            while found.count < 60 {
                let t = LogTime.noon(String(format: "%04d-%02d-01", y, m))
                if t > t1 { break }
                found.append((t, m == 1 ? String(y) : names[m - 1]))
                m += unit.n
                while m > 12 { m -= 12; y += 1 }
            }
        } else {
            var y = parts[0] + 1
            while y % unit.n != 0 { y += 1 }
            while found.count < 60 {
                let t = LogTime.noon(String(format: "%04d-01-01", y))
                if t > t1 { break }
                found.append((t, String(y)))
                y += unit.n
            }
        }
        // Like the web chart, skip ticks that would crowd the plot's edges.
        let span = max(1, t1.timeIntervalSince(t0))
        for (t, label) in found {
            let f = t.timeIntervalSince(t0) / span
            if f < 0.04 || f > 0.96 { continue }
            dates.append(t)
            labels[t] = label
        }
    }
}

// MARK: - TrReadout

/// The line above a chart: the latest value, or the selected one while you drag.
struct TrReadout: View {
    let main: String
    let sub: String
    var live: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(main)
                .font(.logNumber(22))
                .foregroundStyle(live ? LogColor.link : LogColor.ink)
            if !sub.isEmpty {
                Text(sub)
                    .font(.footnote)
                    .foregroundStyle(LogColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Time chart

struct TrSeries: Identifiable {
    enum Kind { case dots, line, smooth, area }
    var id: String
    var kind: Kind
    var color: Color
    var points: [TrendsCalc.Point]
    var faint: Bool = false
    var dashed: Bool = false
    var endDot: Bool = false
    var radius: CGFloat = 3
}

struct TrFocus: Identifiable {
    var id: String
    var point: TrendsCalc.Point
    var color: Color
}

struct TrRef: Identifiable {
    var value: Double
    var label: String
    var inDomain: Bool = true
    var id: String { label }
}

struct TrMark: Identifiable {
    var at: Date
    var label: String
    var id: String { label }
}

typealias TrScrub = (main: String, sub: String)

struct TrSeriesMarks: ChartContent {
    let s: TrSeries
    let pts: [TrendsCalc.Point]
    let lo: Double
    let hi: Double

    func y(_ v: Double) -> Double { min(hi, max(lo, v)) }

    var body: some ChartContent {
        if s.kind == .dots {
            ForEach(0..<pts.count, id: \.self) { i in
                PointMark(x: .value("Date", pts[i].at), y: .value("Value", y(pts[i].value)))
                    .foregroundStyle(s.faint ? s.color.opacity(0.45) : s.color)
                    .symbolSize(s.radius * s.radius * 4)
            }
        } else {
            if s.kind == .area {
                ForEach(0..<pts.count, id: \.self) { i in
                    AreaMark(x: .value("Date", pts[i].at), yStart: .value("Base", lo), yEnd: .value("Value", y(pts[i].value)))
                        .foregroundStyle(s.color.opacity(0.1))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(0..<pts.count, id: \.self) { i in
                LineMark(x: .value("Date", pts[i].at), y: .value("Value", y(pts[i].value)), series: .value("Series", s.id))
                    .foregroundStyle(s.color)
                    .interpolationMethod(s.kind == .line ? .linear : .monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: s.dashed ? [5, 4] : []))
            }
            if s.endDot, let last = pts.last {
                PointMark(x: .value("Date", last.at), y: .value("Value", y(last.value)))
                    .foregroundStyle(s.color)
                    .symbolSize(70)
            }
        }
    }
}

/// A chart on a real time axis (charts.js timeChart): dots, lines, smooth lines and areas,
/// reference lines (goal, target), vertical markers (dose start, switch), and a readout that
/// follows your finger.
struct TrTimeChart: View {
    var t0: Date
    var t1: Date
    var series: [TrSeries]
    var refs: [TrRef] = []
    var marks: [TrMark] = []
    var height: CGFloat = 200
    var yTicks: Int = 4
    var yMin: Double? = nil
    var yMax: Double? = nil
    /// Padding never takes the low end below this (the web's rightMin for zero-based series).
    var yFloor: Double? = nil
    var fmtY: (Double) -> String = { TrendsCalc.num($0) }
    var snap: String
    var readout: TrScrub? = nil
    var scrub: ((TrendsCalc.Point, [String: TrendsCalc.Point]) -> TrScrub)? = nil
    var aria: String = "Chart"
    /// Set to make the chart scroll sideways: this much time shows at once and you swipe back
    /// through the rest. The y axis fits whatever is on screen, so it rescales as you scroll.
    var scrollWindow: TimeInterval? = nil
    /// Where the window first ends (defaults to the end of the chart).
    var scrollInitialEnd: Date? = nil
    @State var selected: Date? = nil
    @State var scrollX: Date? = nil

    var end: Date { max(t1, t0.addingTimeInterval(86400)) }

    /// The window on screen when scrolling (else the whole chart).
    var window: TimeInterval? {
        guard let w = scrollWindow, end.timeIntervalSince(t0) > w * 1.05 else { return nil }
        return w
    }
    var initialFrom: Date {
        guard let w = window else { return t0 }
        let e = min(end, scrollInitialEnd ?? end)
        return max(t0, e.addingTimeInterval(-w))
    }
    var viewFrom: Date { window == nil ? t0 : (scrollX ?? initialFrom) }
    var viewTo: Date { window.map { viewFrom.addingTimeInterval($0) } ?? end }

    func visible(_ s: TrSeries) -> [TrendsCalc.Point] {
        s.points.filter { $0.at >= t0 && $0.at <= end && $0.value.isFinite }
    }

    var scale: TrNiceScale? {
        var vals: [Double] = []
        let viewLo = viewFrom.addingTimeInterval(-86400), viewHi = viewTo.addingTimeInterval(86400)
        for s in series { vals += visible(s).filter { $0.at >= viewLo && $0.at <= viewHi }.map(\.value) }
        if vals.isEmpty { for s in series { vals += visible(s).map(\.value) } }
        for r in refs where r.inDomain && r.value.isFinite { vals.append(r.value) }
        guard let mn = vals.min(), let mx = vals.max() else { return nil }
        var lo = yMin ?? mn
        var hi = yMax ?? mx
        let pad = (hi - lo) * 0.08 == 0 ? 1 : (hi - lo) * 0.08
        if yMin == nil { lo -= pad }
        if let yFloor { lo = max(yFloor, lo) }
        if yMax == nil { hi += pad }
        var sc = TrNiceScale(lo, hi, count: yTicks)
        if let yMin { sc.lo = yMin }
        if let yMax { sc.hi = max(yMax, sc.lo + 1e-6) }
        return sc
    }

    static func nearest(_ pts: [TrendsCalc.Point], _ t: Date) -> TrendsCalc.Point? {
        pts.min { abs($0.at.timeIntervalSince(t)) < abs($1.at.timeIntervalSince(t)) }
    }

    var focus: (point: TrendsCalc.Point, readings: [String: TrendsCalc.Point])? {
        guard let sel = selected, let snapSeries = series.first(where: { $0.id == snap }),
              let p = Self.nearest(visible(snapSeries), sel) else { return nil }
        var readings: [String: TrendsCalc.Point] = [:]
        for s in series {
            if let q = Self.nearest(visible(s), p.at), abs(q.at.timeIntervalSince(p.at)) <= 36 * 3600 { readings[s.id] = q }
        }
        return (p, readings)
    }

    var body: some View {
        let f = focus
        let live: TrScrub? = f.flatMap { scrub?($0.point, $0.readings) }
        VStack(alignment: .leading, spacing: 8) {
            if let r = readout {
                TrReadout(main: live?.main ?? r.main, sub: live?.sub ?? r.sub, live: live != nil)
            }
            if let sc = scale {
                chart(sc, focus: f)
            } else {
                EmptyNote("Not enough data in this range.")
            }
        }
    }

    func chart(_ sc: TrNiceScale, focus f: (point: TrendsCalc.Point, readings: [String: TrendsCalc.Point])?) -> some View {
        let full = max(1, end.timeIntervalSince(t0))
        let ticks = TrTimeTicks(t0, end, width: 300 * CGFloat(full / (window ?? full)))
        let shownRefs = refs.filter { $0.value >= sc.lo && $0.value <= sc.hi }
        let shownMarks = marks.filter { $0.at >= t0 && $0.at <= end }
        let span = max(1, end.timeIntervalSince(t0))
        var focusPoints: [TrFocus] = []
        if let focus = f {
            for s in series where s.kind != .dots || s.id == snap {
                if let p = focus.readings[s.id] { focusPoints.append(TrFocus(id: s.id, point: p, color: s.color)) }
            }
        }
        return Chart {
            ForEach(shownRefs) { r in
                RuleMark(y: .value("Reference", r.value))
                    .foregroundStyle(LogColor.ink2.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text(r.label).font(.caption2.weight(.semibold)).foregroundStyle(LogColor.ink2)
                    }
            }
            ForEach(shownMarks) { m in
                RuleMark(x: .value("Marker", m.at))
                    .foregroundStyle(LogColor.axis)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: m.at.timeIntervalSince(t0) / span > 0.75 ? .leading : .trailing, alignment: .top, spacing: 4) {
                        Text(m.label).font(.caption2.weight(.semibold)).foregroundStyle(LogColor.ink2)
                    }
            }
            ForEach(series) { s in
                TrSeriesMarks(s: s, pts: visible(s), lo: sc.lo, hi: sc.hi)
            }
            if let f {
                RuleMark(x: .value("Selected", f.point.at))
                    .foregroundStyle(LogColor.ink2.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(focusPoints) { item in
                    PointMark(x: .value("Date", item.point.at), y: .value("Value", min(sc.hi, max(sc.lo, item.point.value))))
                        .foregroundStyle(item.color)
                        .symbolSize(100)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: t0...end)
        .chartYScale(domain: sc.lo...sc.hi)
        .chartXAxis {
            AxisMarks(values: ticks.dates) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(ticks.labels[d] ?? LogTime.shortDate(d)).font(.caption2).foregroundStyle(LogColor.ink2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: sc.visibleTicks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(LogColor.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(fmtY(v)).font(.caption2).foregroundStyle(LogColor.ink2)
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .modifier(TrScrollable(window: window, start: initialFrom, x: $scrollX))
        .animation(.easeOut(duration: 0.2), value: sc.lo)
        .animation(.easeOut(duration: 0.2), value: sc.hi)
        .frame(height: height)
        .accessibilityLabel(aria)
    }
}

/// Sideways scrolling for TrTimeChart when it has a window.
struct TrScrollable: ViewModifier {
    var window: TimeInterval?
    var start: Date
    @Binding var x: Date?

    func body(content: Content) -> some View {
        if let window {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: window)
                .chartScrollPosition(x: Binding(get: { x ?? start }, set: { x = $0 }))
        } else {
            content
        }
    }
}

// MARK: - Column chart

/// One column per day (charts.js columnChart), a dashed target, first / middle / last labels.
///
/// The x axis is dates, not day-key strings: Swift Charts draws a label for every category on a
/// string axis whatever `AxisMarks(values:)` says, so 30 days piled up into unreadable text.
/// On a date axis the explicit values are honored, so only three labels show.
struct TrColumnChart: View {
    var columns: [TrendsCalc.Column]
    var color: Color
    var target: Double? = nil
    var targetLabel: String? = nil
    var height: CGFloat = 150
    var fmtY: (Double) -> String = { TrendsCalc.num($0) }
    var main: String
    var sub: String
    var scrub: ((TrendsCalc.Column) -> TrScrub)? = nil
    var aria: String = "Columns"
    @State var selected: Date? = nil

    var scale: TrNiceScale {
        var vals = columns.compactMap { $0.value }.filter(\.isFinite)
        if let target { vals.append(target) }
        var sc = TrNiceScale(0, max(1, vals.max() ?? 1) * 1.05, count: 3)
        sc.lo = 0
        return sc
    }

    static func date(_ key: String) -> Date { LogTime.noon(String(key.prefix(10))) }

    /// First, middle and last day.
    var labelDates: [Date] {
        guard !columns.isEmpty else { return [] }
        let idx = [0, (columns.count - 1) / 2, columns.count - 1]
        var out: [Date] = []
        for i in idx {
            let d = Self.date(columns[i].key)
            if !out.contains(d) { out.append(d) }
        }
        return out
    }

    func anchor(_ d: Date) -> UnitPoint {
        if d == labelDates.first, labelDates.count > 1 { return .topLeading }
        if d == labelDates.last, labelDates.count > 1 { return .topTrailing }
        return .top
    }

    /// The column nearest the finger, within half a day.
    func column(at d: Date?) -> TrendsCalc.Column? {
        guard let d else { return nil }
        let best = columns.min { abs(Self.date($0.key).timeIntervalSince(d)) < abs(Self.date($1.key).timeIntervalSince(d)) }
        guard let best, abs(Self.date(best.key).timeIntervalSince(d)) <= 13 * 3600 else { return nil }
        return best
    }

    var body: some View {
        let sc = scale
        let picked = column(at: selected)
        let live: TrScrub? = picked.flatMap { scrub?($0) }
        let barWidth = MarkDimension.ratio(columns.count > 20 ? 0.7 : 0.6)
        VStack(alignment: .leading, spacing: 8) {
            TrReadout(main: live?.main ?? main, sub: live?.sub ?? sub, live: live != nil)
            Chart {
                ForEach(columns) { c in
                    BarMark(x: .value("Day", Self.date(c.key), unit: .day),
                            y: .value("Value", max(0, c.value ?? 0)),
                            width: barWidth)
                        .foregroundStyle(picked == nil || picked?.key == c.key ? color : color.opacity(0.45))
                        .cornerRadius(3)
                }
                if let target {
                    RuleMark(y: .value("Target", target))
                        .foregroundStyle(LogColor.ink2.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text(targetLabel ?? "Target \(fmtY(target))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LogColor.ink2)
                        }
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...sc.hi)
            .chartXAxis {
                AxisMarks(values: labelDates) { value in
                    AxisValueLabel(anchor: anchor(value.as(Date.self) ?? .distantPast), collisionResolution: .disabled) {
                        if let d = value.as(Date.self) {
                            Text(LogTime.shortDate(d)).font(.caption2).foregroundStyle(LogColor.ink2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: sc.visibleTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(LogColor.grid)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(fmtY(v)).font(.caption2).foregroundStyle(LogColor.ink2)
                        }
                    }
                }
            }
            .chartXSelection(value: $selected)
            .environment(\.calendar, LogTime.calendar)
            .frame(height: height)
            .accessibilityLabel(aria)
        }
    }
}

// MARK: - Scatter

struct TrScatter: View {
    var pairs: [TrendsCalc.Pair]
    var main: String
    var sub: String
    var scrub: (TrendsCalc.Pair) -> TrScrub
    var aria: String = "Scatter"
    @State var selected: Double? = nil

    var body: some View {
        let xs = TrNiceScale(pairs.map(\.x).min() ?? 0, pairs.map(\.x).max() ?? 1, count: 4)
        let ys = TrNiceScale(pairs.map(\.y).min() ?? 0, pairs.map(\.y).max() ?? 1, count: 4)
        let picked: TrendsCalc.Pair? = selected.flatMap { x in pairs.min { abs($0.x - x) < abs($1.x - x) } }
        let live: TrScrub? = picked.map(scrub)
        VStack(alignment: .leading, spacing: 8) {
            TrReadout(main: live?.main ?? main, sub: live?.sub ?? sub, live: live != nil)
            Chart {
                ForEach(pairs) { p in
                    PointMark(x: .value("Across", p.x), y: .value("Up", p.y))
                        .foregroundStyle(LogColor.s1.opacity(picked == nil ? 0.85 : 0.4))
                        .symbolSize(70)
                }
                if let p = picked {
                    PointMark(x: .value("Across", p.x), y: .value("Up", p.y))
                        .foregroundStyle(LogColor.s1)
                        .symbolSize(150)
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: xs.lo...xs.hi)
            .chartYScale(domain: ys.lo...ys.hi)
            .chartXAxis {
                AxisMarks(values: xs.visibleTicks) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Self.tick(v)).font(.caption2).foregroundStyle(LogColor.ink2) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: ys.visibleTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(LogColor.grid)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Self.tick(v)).font(.caption2).foregroundStyle(LogColor.ink2) }
                    }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 220)
            .accessibilityLabel(aria)
        }
    }

    static func tick(_ v: Double) -> String { TrendsCalc.num(v, v.truncatingRemainder(dividingBy: 1) != 0 ? 1 : 0) }
}

// MARK: - TrSparkline

struct TrSparkline: View {
    var points: [TrendsCalc.Point]
    var from: Date
    var to: Date
    var width: CGFloat = 76
    var height: CGFloat = 30

    var body: some View {
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 1
        let pad = hi == lo ? 1.0 : (hi - lo) * 0.12
        let end = max(to, from.addingTimeInterval(3600))
        Chart {
            ForEach(0..<points.count, id: \.self) { i in
                LineMark(x: .value("Date", points[i].at), y: .value("Value", points[i].value))
                    .foregroundStyle(LogColor.s1)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.at), y: .value("Value", last.value))
                    .foregroundStyle(LogColor.s1)
                    .symbolSize(22)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: from...end)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - TrLegend

enum TrKey {
    case line(Color)
    case dashed(Color)
    case dot(Color)
    case faintDot(Color)
    case rect(Color)
    case outlined(Color, Color)
    case ref
}

struct TrLegendItem: Identifiable {
    var key: TrKey
    var label: String
    var id: String { label }
}

struct TrSwatch: View {
    var key: TrKey
    var body: some View {
        switch key {
        case .line(let c):
            Capsule().fill(c).frame(width: 16, height: 2)
        case .dashed(let c):
            HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(c).frame(width: 4, height: 2) } }.frame(width: 16)
        case .dot(let c):
            Circle().fill(c).frame(width: 9, height: 9)
        case .faintDot(let c):
            Circle().fill(c.opacity(0.45)).frame(width: 9, height: 9)
        case .rect(let c):
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
        case .outlined(let fill, let stroke):
            RoundedRectangle(cornerRadius: 3).fill(fill).overlay(RoundedRectangle(cornerRadius: 3).stroke(stroke, lineWidth: 1)).frame(width: 10, height: 10)
        case .ref:
            HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(LogColor.ink2).frame(width: 3, height: 1.5) } }.frame(width: 16)
        }
    }
}

struct TrLegend: View {
    var items: [TrLegendItem]
    var body: some View {
        TrFlow(spacing: 14, lineSpacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    TrSwatch(key: item.key)
                    Text(item.label).font(.caption).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct TrFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 10_000
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        var widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            if x > 0 && x + s.width > maxW {
                y += lineH + lineSpacing
                x = 0
                lineH = 0
            }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += lineH + lineSpacing
                x = bounds.minX
                lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: s.width, height: s.height))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

// MARK: - Text pieces

/// A lead sentence at the top of a card.
struct TrLead: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.body).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
    }
}

/// A small heading inside a card (the web's h3 / hm-group).
struct TrSubHead: View {
    var text: String
    var key: TrKey? = nil
    init(_ text: String, key: TrKey? = nil) { self.text = text; self.key = key }
    var body: some View {
        HStack(spacing: 6) {
            if let key { TrSwatch(key: key) }
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

enum TrTone { case good, watch, steady, crit, quiet }

struct TrBadge: View {
    var text: String
    var tone: TrTone
    init(_ text: String, tone: TrTone) { self.text = text; self.tone = tone }
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Self.ink(tone))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.soft(tone), in: Capsule())
    }
    static func ink(_ t: TrTone) -> Color {
        switch t {
        case .good: return LogColor.goodInk
        case .watch: return LogColor.warnInk
        case .steady: return LogColor.link
        case .crit: return LogColor.critInk
        case .quiet: return LogColor.ink2
        }
    }
    static func soft(_ t: TrTone) -> Color {
        switch t {
        case .good: return LogColor.goodSoft
        case .watch: return LogColor.warnSoft
        case .steady: return LogColor.accentSoft
        case .crit: return LogColor.critSoft
        case .quiet: return LogColor.surface2
        }
    }
}

/// The amber note for something worth watching (the web's callout.watch-note).
struct TrWatchNote: View {
    var title: String
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.warnInk)
            Text(text).font(.footnote).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LogColor.warnSoft, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
    }
}

/// A grid of metric tiles (the web's .tiles of .metric).
struct TrTileGrid: View {
    var tiles: [TrendsCalc.Tile]
    var columns: Int = 2
    var size: CGFloat = 22
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading), count: columns), alignment: .leading, spacing: 10) {
            ForEach(tiles) { t in
                TrTile(label: t.label, value: t.value, detail: t.detail, size: size)
            }
        }
    }
}

struct TrTile: View {
    var label: String
    var value: String
    var detail: String?
    var size: CGFloat = 22
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(LogColor.ink2)
            Text(value).font(.logNumber(size)).foregroundStyle(LogColor.ink).lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Label-value rows with hairlines between (the web's .props).
struct TrProps: View {
    var rows: [(String, String)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { i in
                if i > 0 { Divider().overlay(LogColor.hairline) }
                PropRow(rows[i].0, rows[i].1)
            }
        }
    }
}

/// A bulleted list of receipts.
struct TrReceipts: View {
    var items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<items.count, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(LogColor.ink2)
                    Text(items[i]).foregroundStyle(LogColor.ink).fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
        }
    }
}

/// A table that fits the card width: the first column left, the rest right-aligned numbers.
struct TrTable: View {
    var headers: [String]
    var rows: [[String]]
    var compact: Bool = false
    var leftColumns: Int = 1

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: compact ? 8 : 12, verticalSpacing: compact ? 6 : 8) {
            GridRow {
                ForEach(0..<headers.count, id: \.self) { i in
                    Text(headers[i])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LogColor.ink2)
                        .gridColumnAlignment(i < leftColumns ? .leading : .trailing)
                }
            }
            Divider().overlay(LogColor.hairline)
            ForEach(0..<rows.count, id: \.self) { r in
                GridRow {
                    ForEach(0..<rows[r].count, id: \.self) { i in
                        Text(rows[r][i])
                            .font(cellFont(i))
                            .foregroundStyle(LogColor.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func cellFont(_ i: Int) -> Font {
        if i < leftColumns { return compact ? Font.caption : Font.footnote }
        return Font.logNumber(compact ? 12 : 14, weight: .medium)
    }
}

/// The numbers behind a chart, folded away (the web's dataView).
struct TrDisclosure: View {
    var title: String
    var headers: [String]
    var rows: [[String]]
    var scrolls: Bool = false
    @State var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Group {
                if scrolls {
                    ScrollView(.horizontal, showsIndicators: false) {
                        TrTable(headers: headers, rows: rows, compact: true).fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    TrTable(headers: headers, rows: rows, compact: true)
                }
            }
            .padding(.top, 8)
        } label: {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(LogColor.link)
        }
        .tint(LogColor.link)
    }
}

/// A horizontal bar with its track (the web's bar-track / bar-fill).
struct TrMeter: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(LogColor.surface2)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
