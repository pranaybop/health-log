import Foundation

public enum LogTime {
    nonisolated(unsafe) public private(set) static var zone = TimeZone(identifier: "America/Chicago")!
    nonisolated(unsafe) public private(set) static var calendar: Calendar = makeCalendar(zone)
    /// The zone's standard-time offset (its smaller offset across the year), in seconds.
    nonisolated(unsafe) private static var standardOffset: Int = computeStandardOffset(zone)

    /// Use the person's time zone for days, weeks and times. Call on the main thread, before
    /// computing anything for the screen.
    public static func use(zone newZone: TimeZone) {
        guard newZone.identifier != zone.identifier else { return }
        zone = newZone
        calendar = makeCalendar(newZone)
        standardOffset = computeStandardOffset(newZone)
        rebuildFormatters()
    }

    private static func makeCalendar(_ z: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = z
        c.firstWeekday = 2 // weeks start Monday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private static func computeStandardOffset(_ z: TimeZone) -> Int {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let jan = utcCal.date(from: DateComponents(year: year, month: 1, day: 15)) ?? Date()
        let jul = utcCal.date(from: DateComponents(year: year, month: 7, day: 15)) ?? Date()
        return min(z.secondsFromGMT(for: jan), z.secondsFromGMT(for: jul))
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // MARK: Day keys

    public static func dayKey(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    public static func today(_ now: Date = Date()) -> String { dayKey(now) }

    /// Noon standard time on the key's date in the person's zone (18:00 UTC for Central).
    public static func noon(_ key: String) -> Date {
        utcNoon(key).addingTimeInterval(Double(-standardOffset))
    }

    /// 12:00 UTC on the key's date: an anchor for pure calendar math, whatever the zone.
    private static func utcNoon(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date(timeIntervalSince1970: 0) }
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]; dc.hour = 12
        return utc.date(from: dc) ?? Date(timeIntervalSince1970: 0)
    }

    /// Local midnight at the start of the key's day.
    public static func startOfDay(_ key: String) -> Date {
        calendar.startOfDay(for: noon(key))
    }

    public static func shift(_ key: String, _ days: Int) -> String {
        let d = utc.date(byAdding: .day, value: days, to: utcNoon(key)) ?? utcNoon(key)
        let p = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// Whole days from `b` to `a` (a - b).
    public static func dayDiff(_ a: String, _ b: String) -> Int {
        Int(((utcNoon(a).timeIntervalSince(utcNoon(b))) / 86400).rounded())
    }

    /// Monday of the key's week.
    public static func monday(_ key: String) -> String {
        let weekday = utc.component(.weekday, from: utcNoon(key)) // 1 = Sunday
        return shift(key, -((weekday + 5) % 7))
    }

    /// The last `n` day keys, oldest first, ending today.
    public static func lastDays(_ n: Int, now: Date = Date()) -> [String] {
        let t = today(now)
        return (0..<n).map { shift(t, -(n - 1 - $0)) }
    }

    // MARK: Parsing timestamps

    /// Parses what the payload sends: "2026-11-24T17:29:17+00:00", "2026-11-25T08:01:39.736092+00:00",
    /// "2026-11-25 08:01:39.736092+00", "2026-11-23T18:36:41-06:00", "...Z", or a bare day key (noon).
    public static func parse(_ text: String?) -> Date? {
        guard let s = text?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.count == 10, s.dropFirst(4).first == "-" { return noon(s) }
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
            return String(s[range])
        }
        var dc = DateComponents()
        dc.year = Int(group(1) ?? ""); dc.month = Int(group(2) ?? ""); dc.day = Int(group(3) ?? "")
        dc.hour = Int(group(4) ?? ""); dc.minute = Int(group(5) ?? ""); dc.second = Int(group(6) ?? "0") ?? 0
        guard var date = utc.date(from: dc) else { return nil }
        if let frac = group(7) {
            date += Double("0." + frac) ?? 0
        }
        if let off = group(8) {
            if off != "Z" {
                let sign: Double = off.hasPrefix("-") ? -1 : 1
                let digits = off.dropFirst().replacingOccurrences(of: ":", with: "")
                let hours = Double(digits.prefix(2)) ?? 0
                let minutes = Double(digits.dropFirst(2).prefix(2)) ?? 0
                date -= sign * (hours * 3600 + minutes * 60)
            }
        } else {
            date -= Double(zone.secondsFromGMT(for: date))
        }
        return date
    }

    // MARK: Formatting

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    nonisolated(unsafe) private static var fShort = formatter("MMM d")
    nonisolated(unsafe) private static var fWeekdayShort = formatter("EEE, MMM d")
    nonisolated(unsafe) private static var fLong = formatter("EEEE, MMMM d")
    nonisolated(unsafe) private static var fLongYear = formatter("EEEE, MMMM d, yyyy")
    nonisolated(unsafe) private static var fTime = formatter("h:mm a")
    nonisolated(unsafe) private static var fMonthYear = formatter("MMM yyyy")
    nonisolated(unsafe) private static var fWeekday = formatter("EEEE")

    private static func rebuildFormatters() {
        fShort = formatter("MMM d")
        fWeekdayShort = formatter("EEE, MMM d")
        fLong = formatter("EEEE, MMMM d")
        fLongYear = formatter("EEEE, MMMM d, yyyy")
        fTime = formatter("h:mm a")
        fMonthYear = formatter("MMM yyyy")
        fWeekday = formatter("EEEE")
    }

    /// "Nov 24"
    public static func shortDate(_ date: Date) -> String { fShort.string(from: date) }
    /// "Nov 24" for a day key.
    public static func shortDate(key: String) -> String { fShort.string(from: noon(key)) }
    /// "Tue, Nov 24"
    public static func weekdayDate(_ date: Date) -> String { fWeekdayShort.string(from: date) }
    /// "Tuesday, November 24" (adds the year when it isn't this year)
    public static func longDate(_ date: Date, now: Date = Date()) -> String {
        calendar.component(.year, from: date) == calendar.component(.year, from: now) ? fLong.string(from: date) : fLongYear.string(from: date)
    }
    /// "11:30 AM"
    public static func time(_ date: Date) -> String { fTime.string(from: date) }
    /// "Nov 2026"
    public static func monthYear(_ date: Date) -> String { fMonthYear.string(from: date) }
    /// "Tuesday"
    public static func weekday(_ date: Date) -> String { fWeekday.string(from: date) }

    public static func hour(_ date: Date) -> Int { calendar.component(.hour, from: date) }

    public static func daysUntil(_ date: Date, now: Date = Date()) -> Int {
        dayDiff(dayKey(date), dayKey(now))
    }

    /// "today", "tomorrow", "in 3 days", "yesterday", "3 days ago"
    public static func daysWord(_ n: Int) -> String {
        switch n {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let x where x > 1: return "in \(x) days"
        default: return "\(-n) days ago"
        }
    }

    // MARK: The person's plan dates

    /// When the GLP-1 journey started (the first shot). The defaults are the original log's; the
    /// store sets them from the profile settings (journey_start) or the first logged shot.
    nonisolated(unsafe) public static var tirzStart = parse("2026-11-02T12:00:00-06:00")!
    /// A planned switch to another GLP-1 (settings switch_on), or nil when there isn't one.
    nonisolated(unsafe) public static var switchStart: Date? = parse("2026-12-06T12:00:00-06:00")!
    /// The planned switch, or the far future when there isn't one (so "before the switch" is always true).
    public static var retaStart: Date { switchStart ?? .distantFuture }
    /// Names for the journey's markers ("Tirzepatide", "Retatrutide").
    nonisolated(unsafe) public static var journeyName = "Tirzepatide"
    nonisolated(unsafe) public static var switchName = "Retatrutide"
    /// True when there's a planned switch.
    public static var hasSwitch: Bool { switchStart != nil }
}
