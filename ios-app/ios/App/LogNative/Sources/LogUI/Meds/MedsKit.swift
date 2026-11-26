import SwiftUI
import LogCore

// Small helpers shared by the Meds and Log tabs and the switch card. Internal and prefixed "ML"
// so they can't clash with the other screens' helpers in LogUI.

/// Formatting the way app.js does it.
enum MLFmt {
    /// "Tirzepatide"
    static func cap(_ s: String?) -> String {
        guard let s, let first = s.first else { return "" }
        return first.uppercased() + String(s.dropFirst())
    }
    /// fmtDateCT(d, true): "Sun, Nov 22"
    static func day(_ d: Date) -> String { LogTime.weekdayDate(d) }
    /// fmtDateCT(d, false): "Nov 22"
    static func short(_ d: Date) -> String { LogTime.shortDate(d) }
    /// fmtTimeCT: "4:00 PM CT"
    static func timeCT(_ d: Date) -> String { "\(LogTime.time(d)) CT" }
    /// fmtShortDate(key): "Nov 22", "—" for nil
    static func shortKey(_ key: String?) -> String {
        guard let key, key.count >= 10, Int(key.prefix(4)) != nil else { return "—" }
        return LogTime.shortDate(key: String(key.prefix(10)))
    }
    /// fmtNum(v, v % 1 ? 1 : 0)
    static func auto(_ v: Double) -> String {
        Fmt.num(v, v.truncatingRemainder(dividingBy: 1) != 0 ? 1 : 0)
    }
    /// "3 vials", "1 vial"
    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
    static func days(until d: Date, now: Date = Date()) -> Int { LogTime.daysUntil(d, now: now) }
    /// Site key to words: "Love R" -> "Right love handle"
    static func site(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return Sites.labels[s] ?? s
    }
}

/// A small status pill (the web's .badge).
struct MLBadge: View {
    enum Tone { case good, steady, watch }
    let text: String
    let tone: Tone
    init(_ text: String, _ tone: Tone) { self.text = text; self.tone = tone }
    private var ink: Color {
        switch tone {
        case .good: return LogColor.goodInk
        case .watch: return LogColor.warnInk
        case .steady: return LogColor.link
        }
    }
    private var fill: Color {
        switch tone {
        case .good: return LogColor.goodSoft
        case .watch: return LogColor.warnSoft
        case .steady: return LogColor.accentSoft
        }
    }
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
    }
}

/// A legend entry with a line key (solid or dashed).
struct MLLegendLine: View {
    let color: Color
    let dashed: Bool
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 3] : []))
            }
            .frame(width: 18, height: 8)
            .accessibilityHidden(true)
            Text(label).font(.footnote).foregroundStyle(LogColor.ink2)
        }
    }
}

/// A label, a big value and a detail line (the web's .metric tile).
struct MLTile: View {
    let label: String
    let value: String
    let detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(LogColor.ink2)
            Text(value).font(.logNumber(24)).foregroundStyle(LogColor.ink)
            if let detail { Text(detail).font(.footnote).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A thin divider in the hairline color.
struct MLHairline: View {
    var body: some View { Rectangle().fill(LogColor.hairline).frame(height: 1) }
}

/// Debug-only launch arguments for the CI screenshots.
enum MLDebug {
    /// `-scrollTo <card id>`: scroll the screen to that card when it opens (debug builds only).
    static var scrollTo: String? { arg("-scrollTo") }

    /// The value after a launch argument, in debug builds only.
    static func arg(_ name: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    /// Whether a launch argument is present, in debug builds only.
    static func flag(_ name: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(name)
        #else
        return false
        #endif
    }
}

/// Scrolls to the `-scrollTo` card once the data is there (debug builds only).
struct MLScrollOnLaunch: ViewModifier {
    let proxy: ScrollViewProxy
    let ready: Bool
    func body(content: Content) -> some View {
        content.task(id: ready) {
            guard ready, let target = MLDebug.scrollTo else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            proxy.scrollTo(target, anchor: .top)
        }
    }
}
