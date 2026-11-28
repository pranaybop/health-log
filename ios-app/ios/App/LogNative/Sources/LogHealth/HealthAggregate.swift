import Foundation
import LogCore

public enum HealthAggregate {
    public static let sampleLimit = 20000
    public static let workoutLimit = 1000
    public static let kgToLb = 2.2046226218
    public static let mToMi = 1 / 1609.344
    public static let lToFlOz = 33.814

    public static func jsRound(_ v: Double) -> Double {
        let f = v.rounded(.down)
        return v - f >= 0.5 ? f + 1 : f
    }

    public static func r1(_ v: Double) -> Double { jsRound(v * 10) / 10 }
    public static func r2(_ v: Double) -> Double { jsRound(v * 100) / 100 }

    // MARK: Small helpers

    static func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    public static func words(_ camel: String?) -> String {
        let s = (camel?.isEmpty ?? true) ? "other" : camel!
        guard let re = try? NSRegularExpression(pattern: "([a-z])([A-Z])") else { return s.lowercased() }
        let spaced = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1 $2")
        return spaced.lowercased()
    }

    static func finiteMean(_ list: [Double?]) -> Double? {
        let v = list.compactMap { $0 }.filter { $0.isFinite }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Total length of [start, end] intervals in minutes (ms in, overlaps counted once).
    public static func unionMinutes(_ intervals: [(Double, Double)]) -> Double {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total = 0.0
        var cur: (Double, Double)?
        for (a, b) in sorted {
            if let c = cur, a <= c.1 {
                if b > c.1 { cur = (c.0, b) }
            } else {
                if let c = cur { total += c.1 - c.0 }
                cur = (a, b)
            }
        }
        if let c = cur { total += c.1 - c.0 }
        return total / 60000
    }

    static func byDay(_ list: [HealthSample], _ from: String, _ to: String) -> [(day: String, items: [HealthSample])] {
        var order: [String] = []
        var groups: [String: [HealthSample]] = [:]
        for s in list {
            let key = LogTime.dayKey(s.start)
            guard key >= from && key <= to else { continue }
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key]?.append(s)
        }
        return order.map { (day: $0, items: groups[$0] ?? []) }
    }

    /// Cumulative samples: total per source, and the day takes the biggest source (iPhone and
    /// Watch overlap), never their sum.
    static func sourceMax(_ list: [HealthSample], _ from: String, _ to: String,
                          _ f: (HealthSample) -> Double = { $0.value }) -> [(day: String, value: Double)] {
        var out: [(day: String, value: Double)] = []
        for (day, items) in byDay(list, from, to) {
            var per: [String: Double] = [:]
            for s in items {
                let v = f(s)
                guard v.isFinite else { continue }
                per[s.source, default: 0] += v
            }
            if let best = per.values.max() { out.append((day: day, value: best)) }
        }
        return out
    }

    static func dailyMean(_ list: [HealthSample], _ from: String, _ to: String,
                          _ f: (HealthSample) -> Double = { $0.value }) -> [(day: String, value: Double)] {
        var out: [(day: String, value: Double)] = []
        for (day, items) in byDay(list, from, to) {
            if let m = finiteMean(items.map { Optional(f($0)) }) { out.append((day: day, value: m)) }
        }
        return out
    }

    /// Metrics keyed by day and metric; a later value replaces an earlier one in place.
    struct MetricStore {
        private var order: [String] = []
        private var rows: [String: HealthMetricRow] = [:]

        mutating func put(_ day: String, _ metric: String, _ value: Double?, _ unit: String) {
            guard let value, value.isFinite else { return }
            let key = day + "|" + metric
            if rows[key] == nil { order.append(key) }
            rows[key] = HealthMetricRow(day: day, metric: metric, value: value, unit: unit)
        }

        var list: [HealthMetricRow] { order.compactMap { rows[$0] } }
    }

    // MARK: Sleep

    struct Night {
        var asleep: [(Double, Double)] = []
        var inBed: [(Double, Double)] = []
        var deep = 0.0
        var rem = 0.0
        var core = 0.0
        var awake = 0.0
    }

    private struct Session {
        var end: Double
        var segs: [(a: Double, b: Double, state: String)] = []
    }

    /// Group each source's segments into nights (a gap over 2 hours starts a new one), credit a night
    /// to the day you woke up, and use the source with the most sleep that night. Returns the hours
    /// asleep per day and puts the stage and in-bed metrics.
    static func sleepNights(_ sleep: [HealthSample], _ from: String, _ to: String,
                            into metrics: inout MetricStore) -> [(day: String, hours: Double)] {
        var sourceOrder: [String] = []
        var bySource: [String: [HealthSample]] = [:]
        for s in sleep {
            if bySource[s.source] == nil {
                sourceOrder.append(s.source)
                bySource[s.source] = []
            }
            bySource[s.source]?.append(s)
        }
        var nightOrder: [String] = []
        var nightSources: [String: [String]] = [:]
        var nights: [String: [String: Night]] = [:]
        for src in sourceOrder {
            let list = (bySource[src] ?? []).sorted { ms($0.start) < ms($1.start) }
            var sessions: [Session] = []
            for s in list {
                let a = ms(s.start)
                let b = ms(s.end)
                guard b > a else { continue }
                if sessions.isEmpty || a - sessions[sessions.count - 1].end > 2 * 3_600_000 {
                    sessions.append(Session(end: b))
                }
                let i = sessions.count - 1
                sessions[i].end = Swift.max(sessions[i].end, b)
                sessions[i].segs.append((a: a, b: b, state: s.sleepState ?? "asleep"))
            }
            for ses in sessions {
                let key = LogTime.dayKey(Date(timeIntervalSince1970: ses.end / 1000))
                guard key >= from && key <= to else { continue }
                if nights[key] == nil {
                    nightOrder.append(key)
                    nights[key] = [:]
                    nightSources[key] = []
                }
                var n = nights[key]?[src] ?? Night()
                if nights[key]?[src] == nil { nightSources[key]?.append(src) }
                for g in ses.segs {
                    let min = (g.b - g.a) / 60000
                    if g.state == "inBed" {
                        n.inBed.append((g.a, g.b))
                    } else if g.state == "awake" {
                        n.awake += min
                    } else {
                        n.asleep.append((g.a, g.b))
                        if g.state == "deep" { n.deep += min }
                        else if g.state == "rem" { n.rem += min }
                        else if g.state == "light" { n.core += min }
                    }
                }
                nights[key]?[src] = n
            }
        }
        var hours: [(day: String, hours: Double)] = []
        for key in nightOrder {
            var best: Night?
            var bestMin = 0.0
            var inBedMin = 0.0
            for src in nightSources[key] ?? [] {
                guard let n = nights[key]?[src] else { continue }
                let m = unionMinutes(n.asleep)
                if m > bestMin {
                    bestMin = m
                    best = n
                }
                inBedMin = Swift.max(inBedMin, unionMinutes(n.inBed))
            }
            if let best, bestMin > 0, bestMin <= 24 * 60 {
                hours.append((day: key, hours: r2(bestMin / 60)))
                if best.deep + best.rem + best.core > 0 {
                    metrics.put(key, "sleep_deep_min", jsRound(best.deep), "min")
                    metrics.put(key, "sleep_rem_min", jsRound(best.rem), "min")
                    metrics.put(key, "sleep_core_min", jsRound(best.core), "min")
                    metrics.put(key, "sleep_awake_min", jsRound(best.awake), "min")
                }
            }
            if inBedMin > 0 && inBedMin <= 24 * 60 { metrics.put(key, "sleep_in_bed_h", r2(inBedMin / 60), "h") }
        }
        return hours
    }

    // MARK: The window

    /// `includeDays` adds the per-day totals for log.daily_health.
    public static func collect(_ w: HealthWindowSamples, startKey: String, endKey: String, includeDays: Bool) -> HealthBatch {
        let from = startKey
        let to = endKey
        func inWindow(_ key: String) -> Bool { key >= from && key <= to }
        func sortedDays(_ m: [String: HealthDayStat]) -> [(day: String, stat: HealthDayStat)] {
            m.keys.filter(inWindow).sorted().compactMap { k in m[k].map { (day: k, stat: $0) } }
        }

        var metrics = MetricStore()
        let sleepHours = sleepNights(w.sleep, from, to, into: &metrics)
        var batch = HealthBatch()

        // ---- Per-day totals for log.daily_health ----
        if includeDays {
            var rows: [String: HealthDayRow] = [:]
            for (k, v) in sortedDays(w.steps) { if let s = v.sum { rows[k, default: HealthDayRow(day: k)].steps = jsRound(s) } }
            for (k, v) in sortedDays(w.distance) { if let s = v.sum { rows[k, default: HealthDayRow(day: k)].distanceMi = r2(s * mToMi) } }
            for (k, v) in sortedDays(w.active) { if let s = v.sum { rows[k, default: HealthDayRow(day: k)].activeKcal = jsRound(s) } }
            for (k, v) in sortedDays(w.restingHr) { if let a = v.average { rows[k, default: HealthDayRow(day: k)].restingHr = jsRound(a) } }
            for (k, v) in sourceMax(w.exercise, from, to) { rows[k, default: HealthDayRow(day: k)].exerciseMin = jsRound(v) }
            for (k, v) in sourceMax(w.stand, from, to) { rows[k, default: HealthDayRow(day: k)].standHours = jsRound(v) }
            for (k, items) in byDay(w.vo2, from, to) {
                let vals = items.map(\.value).filter { $0.isFinite }
                if let best = vals.max() { rows[k, default: HealthDayRow(day: k)].vo2max = r1(best) }
            }
            for (k, v) in dailyMean(w.hrv, from, to) { rows[k, default: HealthDayRow(day: k)].hrvMs = jsRound(v) }
            for (k, h) in sleepHours { rows[k, default: HealthDayRow(day: k)].sleepHours = h }
            batch.days = rows.values.filter(\.hasValues).sorted { $0.day < $1.day }
        }

        // ---- Everything else, into log.health_metrics ----
        for (k, v) in sortedDays(w.heartRate) {
            metrics.put(k, "heart_rate_avg", v.average.map(r1), "bpm")
            metrics.put(k, "heart_rate_min", v.min.map(jsRound), "bpm")
            metrics.put(k, "heart_rate_max", v.max.map(jsRound), "bpm")
        }
        let active = w.active
        for (k, v) in sourceMax(w.basal, from, to) {
            metrics.put(k, "basal_kcal", jsRound(v), "kcal")
            if inWindow(k), let a = active[k]?.sum { metrics.put(k, "total_kcal", jsRound(v + a), "kcal") }
        }
        for (k, v) in sourceMax(w.flights, from, to) { metrics.put(k, "flights", jsRound(v), "count") }
        for (k, v) in sourceMax(w.cycling, from, to) where v > 0 { metrics.put(k, "cycling_mi", r2(v * mToMi), "mi") }
        for (k, v) in sortedDays(w.water) { if let s = v.sum, s > 0 { metrics.put(k, "water_oz", jsRound(s * lToFlOz), "fl oz") } }
        for (k, v) in sortedDays(w.dietary) { if let s = v.sum, s > 0 { metrics.put(k, "dietary_kcal", jsRound(s), "kcal") } }
        for (k, items) in byDay(w.glucose, from, to) {
            let vals = items.map(\.value).filter { $0.isFinite }
            guard !vals.isEmpty, let mean = finiteMean(vals) else { continue }
            metrics.put(k, "glucose_avg", jsRound(mean), "mg/dL")
            metrics.put(k, "glucose_min", jsRound(vals.min() ?? mean), "mg/dL")
            metrics.put(k, "glucose_max", jsRound(vals.max() ?? mean), "mg/dL")
        }
        let toF: (HealthSample) -> Double = { s in s.unit == "fahrenheit" ? s.value : s.value * 9 / 5 + 32 }
        for (k, v) in dailyMean(w.bodyTemp, from, to, toF) { metrics.put(k, "body_temp_f", r1(v), "°F") }
        for (k, v) in dailyMean(w.basalTemp, from, to, toF) { metrics.put(k, "basal_temp_f", r1(v), "°F") }
        for (k, v) in dailyMean(w.wristTemp, from, to, toF) { metrics.put(k, "wrist_temp_f", r2(v), "°F") }
        for (k, v) in dailyMean(w.resp, from, to) { metrics.put(k, "respiratory_rate", r1(v), "/min") }
        let pct: (HealthSample) -> Double = { s in s.value <= 1 ? s.value * 100 : s.value }
        for (k, items) in byDay(w.spo2, from, to) {
            let vals = items.map(pct).filter { $0.isFinite }
            guard !vals.isEmpty, let mean = finiteMean(vals) else { continue }
            metrics.put(k, "spo2_avg", r1(mean), "%")
            metrics.put(k, "spo2_min", jsRound(vals.min() ?? mean), "%")
        }
        for (k, items) in byDay(w.bloodPressure, from, to) {
            if let sys = finiteMean(items.map(\.systolic)) { metrics.put(k, "bp_systolic", jsRound(sys), "mmHg") }
            if let dia = finiteMean(items.map(\.diastolic)) { metrics.put(k, "bp_diastolic", jsRound(dia), "mmHg") }
        }
        for (k, v) in sourceMax(w.mindful, from, to) where v > 0 { metrics.put(k, "mindful_min", jsRound(v), "min") }
        for (k, v) in dailyMean(w.mood, from, to) { metrics.put(k, "state_of_mind", r2(v), "valence") }
        for (k, items) in byDay(w.height, from, to) {
            guard let cm = items.last?.value, cm.isFinite, cm > 0 else { continue }
            metrics.put(k, "height_in", r1(cm / 2.54), "in")
        }
        batch.metrics = metrics.list

        // ---- Weigh-ins and body fat: individual readings ----
        for s in w.weights {
            guard s.value.isFinite else { continue }
            let lb = (s.unit == "kilogram" || s.unit == nil) ? s.value * kgToLb : s.value
            batch.weights.append(HealthWeightRow(measuredAt: iso(s.start), weightLb: r1(lb), at: s.start))
        }
        for s in w.bodyFat {
            var p = s.value
            guard p.isFinite else { continue }
            if p <= 1 { p *= 100 } // HealthKit's percent unit is a fraction
            let at = s.start
            batch.body.append(HealthBodyRow(metric: "body_fat_pct", measuredAt: iso(at), value: r1(p), at: at))
            if let wt = batch.weights.first(where: { abs(ms($0.at) - ms(at)) <= 120_000 }) {
                batch.body.append(HealthBodyRow(metric: "lean_mass_lb", measuredAt: iso(at), value: r1(wt.weightLb * (1 - p / 100)), at: at))
            }
        }

        // ---- Workouts ----
        batch.workouts = w.workouts.map { k in
            HealthWorkoutRow(
                startedAt: iso(k.start),
                endedAt: k.end.map(iso),
                activity: words(k.type),
                durationMin: r1(Double(k.durationSeconds) / 60),
                distanceMi: k.distanceMeters.map { r2($0 * mToMi) },
                activeKcal: k.energyKcal.map(jsRound),
                indoor: k.indoor.map { $0 == "1" || $0 == "true" },
                at: k.start
            )
        }
        batch.truncated = w.truncated || w.workouts.count >= workoutLimit
        batch.maxCount = w.maxCount
        return batch
    }

    public static func merge(older: HealthBatch, newer: HealthBatch) -> HealthBatch {
        var out = HealthBatch()
        out.days = older.days + newer.days
        out.weights = uniq(older.weights + newer.weights) { $0.measuredAt }
        out.body = uniq(older.body + newer.body) { "\($0.metric)|\($0.measuredAt)" }
        out.workouts = uniq(older.workouts + newer.workouts) { "\($0.startedAt)|\($0.activity)" }
        out.metrics = older.metrics + newer.metrics
        out.truncated = false
        out.maxCount = Swift.max(older.maxCount, newer.maxCount)
        return out
    }

    /// First position, last value.
    static func uniq<T>(_ list: [T], _ key: (T) -> String) -> [T] {
        var order: [String] = []
        var seen: [String: T] = [:]
        for x in list {
            let k = key(x)
            if seen[k] == nil { order.append(k) }
            seen[k] = x
        }
        return order.compactMap { seen[$0] }
    }

    /// Where collectSafe splits a window that hit a read limit: the older half ends here.
    public static func splitEnd(startKey: String, endKey: String) -> String? {
        let span = LogTime.dayDiff(endKey, startKey) + 1
        guard span > 1 else { return nil }
        return LogTime.shift(startKey, span / 2 - 1)
    }
}
