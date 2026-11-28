import Foundation
import LogCore


/// One reading: a quantity sample, a sleep segment, a stand hour
/// (1 stood, 0 not), a mindful session (minutes), a blood pressure pair or a State of Mind valence.
public struct HealthSample: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var value: Double
    /// "kilogram", "celsius", "percent" ... (some conversions check it).
    public var unit: String?
    /// The app that wrote it (bundle id, else name). Cumulative types are totalled per source.
    public var source: String
    /// Sleep only: inBed, asleep, awake, light (core), deep, rem. nil counts as asleep.
    public var sleepState: String?
    public var systolic: Double?
    public var diastolic: Double?

    public init(start: Date, end: Date? = nil, value: Double, unit: String? = nil, source: String = "?",
                sleepState: String? = nil, systolic: Double? = nil, diastolic: Double? = nil) {
        self.start = start
        self.end = end ?? start
        self.value = value
        self.unit = unit
        self.source = source
        self.sleepState = sleepState
        self.systolic = systolic
        self.diastolic = diastolic
    }
}

public struct HealthDayStat: Equatable, Sendable {
    public var sum: Double?
    public var average: Double?
    public var min: Double?
    public var max: Double?

    public init(sum: Double? = nil, average: Double? = nil, min: Double? = nil, max: Double? = nil) {
        self.sum = sum
        self.average = average
        self.min = min
        self.max = max
    }

    public var hasValue: Bool { sum != nil || average != nil || min != nil || max != nil }
}

public struct HealthWorkoutSample: Equatable, Sendable {
    public var start: Date
    public var end: Date?
    /// CamelCase workout type ("running", "strengthTraining", "other").
    public var type: String
    public var durationSeconds: Int
    public var distanceMeters: Double?
    public var energyKcal: Double?
    /// HKIndoorWorkout metadata as text ("1", "0", "true"), nil when missing.
    public var indoor: String?

    public init(start: Date, end: Date? = nil, type: String, durationSeconds: Int, distanceMeters: Double? = nil,
                energyKcal: Double? = nil, indoor: String? = nil) {
        self.start = start
        self.end = end
        self.type = type
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.energyKcal = energyKcal
        self.indoor = indoor
    }
}

public struct HealthWindowSamples: Sendable {
    public var steps: [String: HealthDayStat] = [:]
    public var distance: [String: HealthDayStat] = [:]
    public var active: [String: HealthDayStat] = [:]
    public var restingHr: [String: HealthDayStat] = [:]
    public var heartRate: [String: HealthDayStat] = [:]
    public var water: [String: HealthDayStat] = [:]
    public var dietary: [String: HealthDayStat] = [:]
    // Samples, oldest first.
    public var exercise: [HealthSample] = []
    public var stand: [HealthSample] = []
    public var vo2: [HealthSample] = []
    public var hrv: [HealthSample] = []
    public var sleep: [HealthSample] = []
    public var basal: [HealthSample] = []
    public var flights: [HealthSample] = []
    public var cycling: [HealthSample] = []
    public var glucose: [HealthSample] = []
    public var bodyTemp: [HealthSample] = []
    public var basalTemp: [HealthSample] = []
    public var wristTemp: [HealthSample] = []
    public var resp: [HealthSample] = []
    public var spo2: [HealthSample] = []
    public var bloodPressure: [HealthSample] = []
    public var mindful: [HealthSample] = []
    public var mood: [HealthSample] = []
    public var height: [HealthSample] = []
    public var weights: [HealthSample] = []
    public var bodyFat: [HealthSample] = []
    public var workouts: [HealthWorkoutSample] = []
    /// A read hit its limit: split the window.
    public var truncated = false
    /// The most samples any one read returned.
    public var maxCount = 0

    public init() {}
}

// MARK: What gets sent

/// A log.daily_health row (only the fields that have a value are sent).
public struct HealthDayRow: Equatable, Sendable {
    public var day: String
    public var steps: Double?
    public var distanceMi: Double?
    public var activeKcal: Double?
    public var restingHr: Double?
    public var exerciseMin: Double?
    public var standHours: Double?
    public var vo2max: Double?
    public var hrvMs: Double?
    public var sleepHours: Double?

    public init(day: String) { self.day = day }

    public var hasValues: Bool {
        [steps, distanceMi, activeKcal, restingHr, exerciseMin, standHours, vo2max, hrvMs, sleepHours].contains { $0 != nil }
    }
}

public struct HealthWeightRow: Equatable, Sendable {
    public var measuredAt: String
    public var weightLb: Double
    /// The reading's time, for pairing with body fat and for the backfill's oldest day.
    public var at: Date
}

public struct HealthBodyRow: Equatable, Sendable {
    public var metric: String  // body_fat_pct | lean_mass_lb
    public var measuredAt: String
    public var value: Double
    public var at: Date
}

public struct HealthWorkoutRow: Equatable, Sendable {
    public var startedAt: String
    public var endedAt: String?
    public var activity: String
    public var durationMin: Double?
    public var distanceMi: Double?
    public var activeKcal: Double?
    public var indoor: Bool?
    public var at: Date
}

public struct HealthMetricRow: Equatable, Sendable {
    public var day: String
    public var metric: String
    public var value: Double
    public var unit: String
}

public struct HealthBatch: Equatable, Sendable {
    public var days: [HealthDayRow] = []
    public var weights: [HealthWeightRow] = []
    public var body: [HealthBodyRow] = []
    public var workouts: [HealthWorkoutRow] = []
    public var metrics: [HealthMetricRow] = []
    public var truncated = false
    public var maxCount = 0

    public init() {}

    /// Rows the backfill counts as "found" (it doesn't send daily totals).
    public var found: Int { metrics.count + weights.count + body.count + workouts.count }

    public var foundDays: [String] {
        let keys = metrics.map(\.day)
            + weights.map { LogTime.dayKey($0.at) }
            + body.map { LogTime.dayKey($0.at) }
            + workouts.map { LogTime.dayKey($0.at) }
        return keys.sorted()
    }
}

/// What a sync stored (counts from the log-write responses).
public struct HealthSyncResult: Sendable {
    public var days = 0
    public var weights = 0
    public var body = 0
    public var workouts = 0
    public var metrics = 0
    public var error: String?
    /// Nothing ran: a sync was already running, or the last one was under a minute ago.
    public var skipped = false
    public init() {}

    /// Everything stored, daily totals included.
    public var stored: Int { days + weights + body + workouts + metrics }
    /// What the backfill counts as values (it doesn't send daily totals).
    public var values: Int { weights + body + workouts + metrics }

    public mutating func add(_ other: HealthSyncResult) {
        days += other.days
        weights += other.weights
        body += other.body
        workouts += other.workouts
        metrics += other.metrics
    }

    /// Add the counts from a log-write response ({ok, days, weights, body, workouts} or {ok, metrics}).
    public mutating func add(response r: [String: Any]) {
        func n(_ k: String) -> Int {
            if let v = r[k] as? NSNumber { return v.intValue }
            if let s = r[k] as? String, let v = Int(s) { return v }
            return 0
        }
        days += n("days")
        weights += n("weights")
        body += n("body")
        workouts += n("workouts")
        metrics += n("metrics")
    }
}

/// The last finished sync (kept in UserDefaults; counts and time only, no health values).
public struct HealthSyncRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var days: Int
    public var weights: Int
    public var body: Int
    public var workouts: Int
    public var metrics: Int

    public init(at: Date, result: HealthSyncResult) {
        self.at = at
        days = result.days
        weights = result.weights
        body = result.body
        workouts = result.workouts
        metrics = result.metrics
    }
}
