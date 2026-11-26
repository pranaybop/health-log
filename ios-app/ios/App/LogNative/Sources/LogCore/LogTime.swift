import Foundation

/// Dates the way the web app does them: every calendar day is an America/Chicago day, written as
/// a "yyyy-MM-dd" key. `noon(key)` is 18:00 UTC on that date (noon CST), the same instant the web
/// app's keyToNoon uses, so day math matches it exactly.
public enum LogTime {
    public static let zone = TimeZone(identifier: "America/Chicago")!

    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.firstWeekday = 2 // weeks start Monday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // MARK: Day keys

    /// "2026-11-24" for the Central-time day `date` falls on.
    public static func dayKey(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    public static func today(_ now: Date = Date()) -> String { dayKey(now) }

    /// 18:00 UTC on the key's date (noon Central standard time).
    public static func noon(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date(timeIntervalSince1970: 0) }
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]; dc.hour = 18
        return utc.date(from: dc) ?? Date(timeIntervalSince1970: 0)
    }

    /// Central midnight at the start of the key's day.
    public static func startOfDay(_ key: String) -> Date {
        calendar.startOfDay(for: noon(key))
    }

    public static func shift(_ key: String, _ days: Int) -> String {
        let d = utc.date(byAdding: .day, value: days, to: noon(key)) ?? noon(key)
        let p = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// Whole days from `b` to `a` (a - b).
    public static func dayDiff(_ a: String, _ b: String) -> Int {
        Int(((noon(a).timeIntervalSince(noon(b))) / 86400).rounded())
    }

    /// Monday of the key's week.
    public static func monday(_ key: String) -> String {
        let weekday = utc.component(.weekday, from: noon(key)) // 1 = Sunday
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
            // No offset: treat as Central time, like a time typed on the phone.
            date -= Double(zone.secondsFromGMT(for: date))
        }
        return date
    }

    // MARK: Formatting (Central time, en_US)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    private static let fShort = formatter("MMM d")
    private static let fWeekdayShort = formatter("EEE, MMM d")
    private static let fLong = formatter("EEEE, MMMM d")
    private static let fLongYear = formatter("EEEE, MMMM d, yyyy")
    private static let fTime = formatter("h:mm a")
    private static let fMonthYear = formatter("MMM yyyy")
    private static let fWeekday = formatter("EEEE")

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

    /// Hour of the day in Central time, 0-23.
    public static func hour(_ date: Date) -> Int { calendar.component(.hour, from: date) }

    /// Whole days from now until `date` (negative if past), by Central calendar days.
    public static func daysUntil(_ date: Date, now: Date = Date()) -> Int {
        dayDiff(dayKey(date), dayKey(now))
    }

    // MARK: Fixed dates in the plan

    /// First tirzepatide dose.
    public static let tirzStart = parse("2026-11-02T12:00:00-06:00")!
    /// Planned switch to retatrutide.
    public static let retaStart = parse("2026-12-06T12:00:00-06:00")!
}
