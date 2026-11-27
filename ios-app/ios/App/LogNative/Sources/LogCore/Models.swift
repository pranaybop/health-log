import Foundation

// The dashboard payload from the log-dashboard Edge Function (public.log_dashboard_payload()).
// Keys are snake_case in JSON and camelCase here (decoded with .convertFromSnakeCase).
// Timestamps stay strings as sent; use `LogTime.parse(_:)` (or the `...Date` helpers) for Dates.

public struct Meal: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var eatenAt: String?
    public var mealType: String?
    public var item: String?
    public var quantity: String?
    @Flex public var calories: Double?
    @Flex public var proteinG: Double?
    @Flex public var carbsG: Double?
    @Flex public var fatG: Double?
    @Flex public var fiberG: Double?
    public var source: String?
    public var notes: String?
    public var eatenDate: Date? { LogTime.parse(eatenAt) }
}

public struct WeightEntry: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var measuredAt: String?
    @Flex public var weightLb: Double?
    public var notes: String?
    public var measuredDate: Date? { LogTime.parse(measuredAt) }
}

public struct Dose: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var takenAt: String?
    public var compound: String?
    @Flex public var doseMg: Double?
    @Flex public var units: Double?
    public var site: String?
    public var skipped: Bool?
    public var notes: String?
    public var takenDate: Date? { LogTime.parse(takenAt) }
    /// Not skipped, with a time and an amount.
    public var counts: Bool { skipped != true && takenDate != nil && doseMg != nil }
}

public struct DailyTotal: Codable, Hashable, Sendable {
    public var date: String
    @Flex public var calories: Double?
    @Flex public var proteinG: Double?
    @Flex public var carbsG: Double?
    @Flex public var fatG: Double?
    @Flex public var fiberG: Double?
    @Flex public var mealCount: Double?
}

public struct WeeklySummary: Codable, Hashable, Sendable {
    public var week: String
    @Flex public var avgDailyCalories: Double?
    @Flex public var avgProteinG: Double?
    @Flex public var calories: Double?
    @Flex public var daysLogged: Double?
    @Flex public var minWeightLb: Double?
    @Flex public var maxWeightLb: Double?
    @Flex public var avgWeightLb: Double?
}

public struct DailyHealth: Codable, Hashable, Sendable {
    public var day: String
    @Flex public var steps: Double?
    @Flex public var distanceMi: Double?
    @Flex public var activeKcal: Double?
    @Flex public var exerciseMin: Double?
    @Flex public var standHours: Double?
    @Flex public var restingHr: Double?
    @Flex public var hrvMs: Double?
    @Flex public var vo2max: Double?
    @Flex public var sleepHours: Double?
    public var source: String?
}

/// One day's value of a log.health_metrics metric, sent as `["2026-11-24", 72.4]`.
public struct MetricPoint: Codable, Hashable, Sendable {
    public var day: String
    public var value: Double

    public init(day: String, value: Double) {
        self.day = day
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        day = try c.decode(String.self)
        let v = try c.decode(Flex.self)
        value = v.wrappedValue ?? .nan
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(day)
        try c.encode(value)
    }
}

public struct Workout: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var startedAt: String?
    public var endedAt: String?
    public var activity: String?
    @Flex public var durationMin: Double?
    @Flex public var distanceMi: Double?
    @Flex public var activeKcal: Double?
    @Flex public var avgHr: Double?
    @Flex public var maxHr: Double?
    public var indoor: Bool?
    public var source: String?
    public var startedDate: Date? { LogTime.parse(startedAt) }
}

public struct HealthSpan: Codable, Hashable, Sendable {
    public var firstDay: String?
    public var lastDay: String?
    @Flex public var days: Double?
}

public struct Checkin: Codable, Hashable, Sendable {
    public var day: String
    public var ateVsUsual: String?      // less | usual | more
    public var movedVsUsual: String?    // less | usual | more
    public var doseFeel: String?        // strong | fading | not_feeling_it
    @Flex public var mood: Double?      // 1-10
    @Flex public var foodNoise: Double?
    @Flex public var energy: Double?
    @Flex public var sleepQuality: Double?
    @Flex public var sleepHours: Double?
    @Flex public var exerciseMinutes: Double?
    @Flex public var steps: Double?
    @Flex public var restingHr: Double?
    @Flex public var activeCalories: Double?
    public var earned: Bool?
    public var notes: String?
    public var source: String?
}

public struct SideEffect: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var recordedOn: String?
    public var recordedAt: String?
    public var effect: String?
    @Flex public var severity: Double?
    public var notes: String?
}

public struct FoodThought: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var thoughtAt: String?
    @Flex public var strength: Double?  // 1 passing thought, 2 strong pull, 3 craving
    public var note: String?
    public var thoughtDate: Date? { LogTime.parse(thoughtAt) }
}

public struct ProtocolRow: Codable, Hashable, Sendable {
    @FlexText public var id: String?
    public var compound: String?
    public var displayName: String?
    @Flex public var typicalDoseMg: Double?
    @Flex public var units: Double?
    public var frequency: String?
    public var status: String?
    @Flex public var halfLifeHours: Double?
    public var startedOn: String?
    public var nextSite: String?
    public var notes: String?
}

/// A planned weekly dose (log.dose_plan). Planned only; what was taken is in `doses`.
public struct DosePlanRow: Codable, Hashable, Sendable {
    public var plannedOn: String
    @Flex public var week: Double?
    public var compound: String?
    @Flex public var doseMg: Double?
    @Flex public var units: Double?
    public var vialDraw: String?
    public var notes: String?
}

public struct Vial: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var compound: String?
    public var label: String?
    public var startedOn: String?
    public var openedAt: String?
    @Flex public var totalMg: Double?
    @Flex public var remainingMg: Double?
    @Flex public var totalUnits: Double?
    @Flex public var remainingUnits: Double?
    @Flex public var concentrationMgPerMl: Double?
    public var expiredOn: String?
    public var notes: String?
}

public struct Measurement: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var measuredAt: String?
    public var metric: String?
    @Flex public var value: Double?
    public var unit: String?
    public var notes: String?
    public var measuredDate: Date? { LogTime.parse(measuredAt) }
}

public struct Profile: Codable, Hashable, Sendable {
    @Flex public var startWeightLb: Double?
    @Flex public var goalWeightLb: Double?
    @Flex public var heightIn: Double?
    public var notes: String?
    /// IANA time zone for this person's days ("America/Chicago").
    public var timeZone: String?
    public var displayName: String?
    /// Set when first-run setup finished. Nil for a new account.
    public var onboardedAt: String?
    public var settings: ProfileSettings?

    enum CodingKeys: String, CodingKey {
        case startWeightLb, goalWeightLb, heightIn, notes, timeZone, displayName, onboardedAt, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _startWeightLb = (try? c.decode(Flex.self, forKey: .startWeightLb)) ?? Flex()
        _goalWeightLb = (try? c.decode(Flex.self, forKey: .goalWeightLb)) ?? Flex()
        _heightIn = (try? c.decode(Flex.self, forKey: .heightIn)) ?? Flex()
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        timeZone = try? c.decodeIfPresent(String.self, forKey: .timeZone)
        displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        onboardedAt = try? c.decodeIfPresent(String.self, forKey: .onboardedAt)
        settings = try? c.decodeIfPresent(ProfileSettings.self, forKey: .settings)
    }
}

/// Per-person settings kept in the profile (profile.settings). Every field is optional; the app
/// falls back to what the data shows.
public struct ProfileSettings: Codable, Hashable, Sendable {
    /// "yyyy-MM-dd": the first GLP-1 shot (else the first logged shot).
    public var journeyStart: String?
    /// "yyyy-MM-dd": a planned switch to another GLP-1, if any.
    public var switchOn: String?
    /// The compound switched to on switchOn ("retatrutide").
    public var switchCompound: String?
    /// "bot" (the Grok Log bot) or "app" (describe a meal in the app with your own AI key).
    public var mealLogging: String?

    public init(journeyStart: String? = nil, switchOn: String? = nil, switchCompound: String? = nil, mealLogging: String? = nil) {
        self.journeyStart = journeyStart
        self.switchOn = switchOn
        self.switchCompound = switchCompound
        self.mealLogging = mealLogging
    }

    enum CodingKeys: String, CodingKey { case journeyStart, switchOn, switchCompound, mealLogging }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        journeyStart = try? c.decodeIfPresent(String.self, forKey: .journeyStart)
        switchOn = try? c.decodeIfPresent(String.self, forKey: .switchOn)
        switchCompound = try? c.decodeIfPresent(String.self, forKey: .switchCompound)
        mealLogging = try? c.decodeIfPresent(String.self, forKey: .mealLogging)
    }
}

/// Who the payload is for: a signed-in account, or the owner via the passcode.
public struct Account: Codable, Hashable, Sendable {
    public var kind: String?
    public var email: String?
}

public struct Goal: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var kind: String?
    @Flex public var target: Double?
    public var unit: String?
    public var dueOn: String?
    public var notes: String?
    public var status: String?
}

/// A private progress photo linked to a weigh-in. `url` is a short-lived signed URL
/// from log-dashboard; the object itself stays in a private bucket.
public struct ProgressPhoto: Codable, Hashable, Sendable, Identifiable {
    @FlexText public var id: String?
    public var takenAt: String?
    public var day: String?
    @Flex public var weightLb: Double?
    @FlexText public var weightId: String?
    public var notes: String?
    public var url: String?
    public var takenDate: Date? { LogTime.parse(takenAt) }
    /// Stable identity for lists. The server id is a uuid; fall back so a row still renders.
    public var stableID: String { id ?? "\(day ?? "")|\(takenAt ?? "")|\(weightLb ?? 0)" }
}

public struct Dashboard: Codable, Sendable {
    public var asOf: String?
    public var meals: [Meal]
    public var weights: [WeightEntry]
    public var doses: [Dose]
    public var dailyTotals: [DailyTotal]
    public var weeklySummary: [WeeklySummary]
    public var dailyHealth: [DailyHealth]
    public var healthMetrics: [String: [MetricPoint]]
    public var workouts: [Workout]
    public var workoutCount: Int?
    public var healthSpan: HealthSpan?
    public var checkins: [Checkin]
    public var sideEffects: [SideEffect]
    public var foodThoughts: [FoodThought]
    public var protocols: [ProtocolRow]
    public var dosePlan: [DosePlanRow]
    public var vials: [Vial]
    public var measurements: [Measurement]
    public var profile: Profile?
    public var goals: [Goal]
    public var progressPhotos: [ProgressPhoto]
    /// Daily (and other non-weekly) peptide schedules, such as tesamorelin (log.regimen).
    public var regimens: [Regimen]
    /// Logged doses of those peptides. Kept apart from `doses`, which is GLP-1 shots only, so
    /// levels, site rotation and the weekly plan never count a daily peptide as a GLP-1 shot.
    public var peptideDoses: [Dose]
    public var account: Account?

    enum CodingKeys: String, CodingKey {
        case asOf, meals, weights, doses, dailyTotals, weeklySummary, dailyHealth, healthMetrics, workouts
        case workoutCount, healthSpan, checkins, sideEffects, foodThoughts
        case protocols = "protocol"
        case dosePlan, vials, measurements, profile, goals, progressPhotos, regimens, peptideDoses, account
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable>(_ key: CodingKeys) -> [T] { (try? c.decodeIfPresent([T].self, forKey: key)) ?? nil ?? [] }
        asOf = try? c.decodeIfPresent(String.self, forKey: .asOf)
        meals = list(.meals)
        weights = list(.weights)
        let allDoses: [Dose] = list(.doses)
        doses = allDoses.filter { Dose.isGLP1($0.compound) }
        peptideDoses = allDoses.filter { !Dose.isGLP1($0.compound) } + (list(.peptideDoses) as [Dose])
        dailyTotals = list(.dailyTotals)
        weeklySummary = list(.weeklySummary)
        dailyHealth = list(.dailyHealth)
        healthMetrics = (try? c.decodeIfPresent([String: [MetricPoint]].self, forKey: .healthMetrics)) ?? nil ?? [:]
        workouts = list(.workouts)
        workoutCount = try? c.decodeIfPresent(Int.self, forKey: .workoutCount)
        healthSpan = try? c.decodeIfPresent(HealthSpan.self, forKey: .healthSpan)
        checkins = list(.checkins)
        sideEffects = list(.sideEffects)
        foodThoughts = list(.foodThoughts)
        protocols = list(.protocols)
        dosePlan = list(.dosePlan)
        vials = list(.vials)
        measurements = list(.measurements)
        profile = try? c.decodeIfPresent(Profile.self, forKey: .profile)
        goals = list(.goals)
        progressPhotos = list(.progressPhotos)
        regimens = list(.regimens)
        account = try? c.decodeIfPresent(Account.self, forKey: .account)
    }

    public var asOfDate: Date? { LogTime.parse(asOf) }

    /// Decode the payload as the Edge Function sends it.
    public static func decode(_ data: Data) throws -> Dashboard {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Dashboard.self, from: data)
    }
}
