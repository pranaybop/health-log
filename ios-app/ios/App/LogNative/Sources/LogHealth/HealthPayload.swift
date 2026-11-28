import Foundation

public enum HealthPayload {
    public struct Request {
        public let action: String
        public let payload: [String: Any]
    }

    public static func requests(for b: HealthBatch) -> [Request] {
        var out: [Request] = []
        for part in chunk(b.days, 31) { out.append(Request(action: "health_sync", payload: ["days": part.map { json($0) }])) }
        for part in chunk(b.weights, 150) { out.append(Request(action: "health_sync", payload: ["weights": part.map { json($0) }])) }
        for part in chunk(b.body, 150) { out.append(Request(action: "health_sync", payload: ["body": part.map { json($0) }])) }
        for part in chunk(b.workouts, 80) { out.append(Request(action: "health_sync", payload: ["workouts": part.map { json($0) }])) }
        for part in chunk(b.metrics, 300) { out.append(Request(action: "health_metrics", payload: ["metrics": part.map { json($0) }])) }
        return out
    }

    public static func chunk<T>(_ list: [T], _ size: Int) -> [[T]] {
        guard size > 0 else { return [list] }
        return stride(from: 0, to: list.count, by: size).map { Array(list[$0..<min($0 + size, list.count)]) }
    }

    public static func number(_ v: Double) -> Any {
        if v == v.rounded(), abs(v) < 1e15 { return Int(v) }
        return Decimal(string: "\(v)", locale: Locale(identifier: "en_US_POSIX")) ?? v
    }

    static func json(_ d: HealthDayRow) -> [String: Any] {
        var o: [String: Any] = ["day": d.day]
        func set(_ k: String, _ v: Double?) { if let v { o[k] = number(v) } }
        set("steps", d.steps)
        set("distance_mi", d.distanceMi)
        set("active_kcal", d.activeKcal)
        set("resting_hr", d.restingHr)
        set("exercise_min", d.exerciseMin)
        set("stand_hours", d.standHours)
        set("vo2max", d.vo2max)
        set("hrv_ms", d.hrvMs)
        set("sleep_hours", d.sleepHours)
        return o
    }

    static func json(_ w: HealthWeightRow) -> [String: Any] {
        ["measured_at": w.measuredAt, "weight_lb": number(w.weightLb)]
    }

    static func json(_ b: HealthBodyRow) -> [String: Any] {
        ["metric": b.metric, "measured_at": b.measuredAt, "value": number(b.value)]
    }

    static func json(_ k: HealthWorkoutRow) -> [String: Any] {
        func opt(_ v: Double?) -> Any { v.map(number) ?? NSNull() }
        return [
            "started_at": k.startedAt,
            "ended_at": k.endedAt.map { $0 as Any } ?? NSNull(),
            "activity": k.activity,
            "duration_min": opt(k.durationMin),
            "distance_mi": opt(k.distanceMi),
            "active_kcal": opt(k.activeKcal),
            "indoor": k.indoor.map { $0 as Any } ?? NSNull(),
        ]
    }

    static func json(_ m: HealthMetricRow) -> [String: Any] {
        ["day": m.day, "metric": m.metric, "value": number(m.value), "unit": m.unit]
    }
}
