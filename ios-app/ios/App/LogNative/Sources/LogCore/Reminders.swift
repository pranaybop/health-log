import Foundation

// Local reminders: what to schedule, with no UserNotifications here so it can be tested.
// The phone turns these into notifications. Times are America/Chicago, like the rest of Log.

public struct ReminderSettings: Codable, Equatable, Sendable {
    public var shot: Bool
    public var shotHour: Int
    public var shotMinute: Int
    public var checkin: Bool
    public var checkinHour: Int
    public var checkinMinute: Int
    public var weighIn: Bool
    public var weighHour: Int
    public var weighMinute: Int
    /// The dose plan's "Remind me" offer was dismissed.
    public var shotPromptDismissed: Bool

    public static let storageKey = "log.reminders"

    public init(shot: Bool = false, shotHour: Int = 9, shotMinute: Int = 0,
                checkin: Bool = false, checkinHour: Int = 18, checkinMinute: Int = 0,
                weighIn: Bool = false, weighHour: Int = 8, weighMinute: Int = 0,
                shotPromptDismissed: Bool = false) {
        self.shot = shot
        self.shotHour = Self.hour(shotHour, 9)
        self.shotMinute = Self.minute(shotMinute)
        self.checkin = checkin
        self.checkinHour = Self.hour(checkinHour, 18)
        self.checkinMinute = Self.minute(checkinMinute)
        self.weighIn = weighIn
        self.weighHour = Self.hour(weighHour, 8)
        self.weighMinute = Self.minute(weighMinute)
        self.shotPromptDismissed = shotPromptDismissed
    }

    public static func load(_ defaults: UserDefaults = .standard) -> ReminderSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(ReminderSettings.self, from: data) else { return ReminderSettings() }
        return settings
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// "9:00 AM"
    public static func clock(_ hour: Int, _ minute: Int) -> String {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        guard let date = LogTime.calendar.date(from: parts) else { return "" }
        return LogTime.time(date)
    }

    private static func hour(_ value: Int, _ fallback: Int) -> Int {
        (0...23).contains(value) ? value : fallback
    }
    private static func minute(_ value: Int) -> Int { (0...59).contains(value) ? value : 0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ReminderSettings()
        shot = try c.decodeIfPresent(Bool.self, forKey: .shot) ?? base.shot
        shotHour = Self.hour(try c.decodeIfPresent(Int.self, forKey: .shotHour) ?? base.shotHour, base.shotHour)
        shotMinute = Self.minute(try c.decodeIfPresent(Int.self, forKey: .shotMinute) ?? base.shotMinute)
        checkin = try c.decodeIfPresent(Bool.self, forKey: .checkin) ?? base.checkin
        checkinHour = Self.hour(try c.decodeIfPresent(Int.self, forKey: .checkinHour) ?? base.checkinHour, base.checkinHour)
        checkinMinute = Self.minute(try c.decodeIfPresent(Int.self, forKey: .checkinMinute) ?? base.checkinMinute)
        weighIn = try c.decodeIfPresent(Bool.self, forKey: .weighIn) ?? base.weighIn
        weighHour = Self.hour(try c.decodeIfPresent(Int.self, forKey: .weighHour) ?? base.weighHour, base.weighHour)
        weighMinute = Self.minute(try c.decodeIfPresent(Int.self, forKey: .weighMinute) ?? base.weighMinute)
        shotPromptDismissed = try c.decodeIfPresent(Bool.self, forKey: .shotPromptDismissed) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case shot, shotHour, shotMinute, checkin, checkinHour, checkinMinute
        case weighIn, weighHour, weighMinute, shotPromptDismissed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shot, forKey: .shot)
        try c.encode(shotHour, forKey: .shotHour)
        try c.encode(shotMinute, forKey: .shotMinute)
        try c.encode(checkin, forKey: .checkin)
        try c.encode(checkinHour, forKey: .checkinHour)
        try c.encode(checkinMinute, forKey: .checkinMinute)
        try c.encode(weighIn, forKey: .weighIn)
        try c.encode(weighHour, forKey: .weighHour)
        try c.encode(weighMinute, forKey: .weighMinute)
        try c.encode(shotPromptDismissed, forKey: .shotPromptDismissed)
    }
}

public struct ReminderRequest: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    /// "meds", "checkin", or "weigh": the screen a tap opens.
    public var route: String
    /// Nil repeats every day. A day key fires once, on that day.
    public var day: String?
    public var hour: Int
    public var minute: Int

    public init(id: String, title: String, body: String, route: String, day: String?, hour: Int, minute: Int) {
        self.id = id
        self.title = title
        self.body = body
        self.route = route
        self.day = day
        self.hour = hour
        self.minute = minute
    }
}

public enum ReminderPlanner {
    /// Days after a missed dose to keep reminding, stopping before the next planned dose.
    public static let maxCatchUpDays = 6

    public static func requests(_ d: Dashboard, settings: ReminderSettings, now: Date) -> [ReminderRequest] {
        var out: [ReminderRequest] = []
        if settings.checkin {
            out.append(ReminderRequest(
                id: "log.checkin", title: "Check in", body: "How you ate, moved, felt and slept.",
                route: "checkin", day: nil, hour: settings.checkinHour, minute: settings.checkinMinute))
        }
        if settings.weighIn {
            out.append(ReminderRequest(
                id: "log.weigh", title: "Weigh in", body: "Log this morning's weight.",
                route: "weigh", day: nil, hour: settings.weighHour, minute: settings.weighMinute))
        }
        if settings.shot { out.append(contentsOf: shots(d, settings: settings, now: now)) }
        return out
    }

    /// The Central-time instant of hour:minute on a day key.
    public static func fireDate(_ day: String, _ hour: Int, _ minute: Int) -> Date? {
        var parts = LogTime.calendar.dateComponents([.year, .month, .day], from: LogTime.noon(day))
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        return LogTime.calendar.date(from: parts)
    }

    private static func shots(_ d: Dashboard, settings: ReminderSettings, now: Date) -> [ReminderRequest] {
        let open = Analytics.openPlan(d)
        guard let first = open.first else { return [] }
        var out: [ReminderRequest] = []
        for row in open {
            if let at = fireDate(row.plannedOn, settings.shotHour, settings.shotMinute), at > now {
                out.append(shotDay(row, day: row.plannedOn, settings: settings))
            }
        }
        // Keep mentioning the earliest open dose on the days after it was due, including when
        // that was weeks ago, and stop before the next planned day that hasn't arrived yet.
        let today = LogTime.today(now)
        var day = LogTime.shift(first.plannedOn, 1)
        if day < today { day = today }
        let later = open.dropFirst().first { $0.plannedOn > today }?.plannedOn
        let stop = later ?? LogTime.shift(max(today, first.plannedOn), maxCatchUpDays + 1)
        var n = 0
        while day < stop && n < maxCatchUpDays {
            if let at = fireDate(day, settings.shotHour, settings.shotMinute), at > now {
                out.append(overdue(first, on: day, settings: settings))
                n += 1
            }
            day = LogTime.shift(day, 1)
        }
        return out
    }

    private static func doseName(_ row: DosePlanRow) -> String {
        let raw = row.compound ?? ""
        let name = raw.isEmpty ? "Dose" : raw.prefix(1).uppercased() + raw.dropFirst()
        guard let mg = row.doseMg else { return name }
        return "\(name) \(String(format: "%.1f", mg)) mg"
    }

    private static func shotDay(_ row: DosePlanRow, day: String, settings: ReminderSettings) -> ReminderRequest {
        ReminderRequest(
            id: "log.shot.\(row.plannedOn)", title: "Shot day", body: "\(doseName(row)) today.",
            route: "meds", day: day, hour: settings.shotHour, minute: settings.shotMinute)
    }

    private static func overdue(_ row: DosePlanRow, on day: String, settings: ReminderSettings) -> ReminderRequest {
        let when = LogTime.weekdayDate(LogTime.noon(row.plannedOn))
        return ReminderRequest(
            id: "log.shot.\(row.plannedOn).due.\(day)", title: "Dose overdue",
            body: "\(doseName(row)) was planned for \(when). Log it or skip it.",
            route: "meds", day: day, hour: settings.shotHour, minute: settings.shotMinute)
    }
}
