import SwiftUI
import UIKit
import LogCore


enum TodayTone {
    case plain, good, watch, steady

    var soft: Color {
        switch self {
        case .plain: return LogColor.surface
        case .good: return LogColor.goodSoft
        case .watch: return LogColor.warnSoft
        case .steady: return LogColor.accentSoft
        }
    }

    var ink: Color {
        switch self {
        case .plain: return LogColor.ink
        case .good: return LogColor.goodInk
        case .watch: return LogColor.warnInk
        case .steady: return LogColor.link
        }
    }
}

struct TodayChip: View {
    let text: String
    var tone: TodayTone = .plain
    /// Plain chips sit on the page background, so they use the card color; inside a card, the inset color.
    var inCard = false

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tone.ink)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(tone == .plain && inCard ? LogColor.surface2 : tone.soft, in: Capsule())
    }
}

struct TodayTile: View {
    let label: String
    let value: String
    var detail: String?
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 26

    init(label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.footnote.weight(.medium)).foregroundStyle(LogColor.ink2)
            Text(value).font(.logNumber(min(size, 40), weight: .semibold)).foregroundStyle(LogColor.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: LogMetric.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct TileData: Identifiable {
    let label: String
    let value: String
    var detail: String?
    var id: String { label }
}

/// Tiles two to a row, each row as tall as its tallest tile.
struct TileGrid: View {
    let tiles: [TileData]

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { i in
                GridRow {
                    TodayTile(label: tiles[i].label, value: tiles[i].value, detail: tiles[i].detail)
                    if i + 1 < tiles.count {
                        TodayTile(label: tiles[i + 1].label, value: tiles[i + 1].value, detail: tiles[i + 1].detail)
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }
}

struct TodayProps: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Rectangle().fill(LogColor.hairline).frame(height: 1) }
                PropRow(row.0, row.1)
            }
        }
    }
}

struct TodayCallout<Trailing: View>: View {
    let title: String
    let detail: String
    var tone: TodayTone = .steady
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(tone == .good ? LogColor.goodInk : LogColor.ink)
                Text(detail).font(.subheadline).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 14)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .background(tone == .plain ? LogColor.surface : tone.soft, in: RoundedRectangle(cornerRadius: LogMetric.cardRadius, style: .continuous))
    }
}

struct TodayLink: View {
    let title: String
    var color: Color = LogColor.link
    let action: () -> Void

    init(_ title: String, color: Color = LogColor.link, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
    }
}

struct TodayCaption: View {
    let text: String
    var color: Color = LogColor.ink2
    init(_ text: String, color: Color = LogColor.ink2) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        var widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, maxW)
            if x > 0 && x + w > maxW {
                y += lineH + lineSpacing
                x = 0
                lineH = 0
            }
            x += w + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX {
                y += lineH + lineSpacing
                x = bounds.minX
                lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: s.height))
            x += w + spacing
            lineH = max(lineH, s.height)
        }
    }
}

/// Chips (or anything) in rows that wrap.
struct Wrap<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: spacing).callAsFunction(content)
    }
}

/// A rounded bar filled to a share (0...1).
struct ShareBar: View {
    let share: Double
    let color: Color
    var track: Color = LogColor.surface2
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: max(0, min(1, share)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}


enum TodayText {
    static func timeCT(_ d: Date) -> String { LogTime.time(d) + " CT" }

    static func weekdayDateYear(_ d: Date, now: Date) -> String {
        let y = LogTime.calendar.component(.year, from: d)
        return y == LogTime.calendar.component(.year, from: now) ? LogTime.weekdayDate(d) : "\(LogTime.weekdayDate(d)), \(y)"
    }

    static func daysWord(_ n: Int) -> String {
        if n == 0 { return "today" }
        if n == 1 { return "tomorrow" }
        if n < 0 { return "\(-n) day\(n == -1 ? "" : "s") ago" }
        return "in \(n) days"
    }

    static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return "" }
        return String(first).uppercased() + s.dropFirst()
    }

    /// "1 meal" / "4 meals"
    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    static func plain(_ v: Double?) -> String { Fmt.mg(v) }

    static func dayTitle(_ key: String, today: String, now: Date) -> String {
        let off = LogTime.dayDiff(key, today)
        if off == 0 { return "Today" }
        if off == -1 { return "Yesterday" }
        let d = LogTime.noon(key)
        if off > -7 { return LogTime.weekday(d) }
        return weekdayDateYear(d, now: now)
    }

    static func writeError(_ error: Error) -> String {
        if let e = error as? LogError {
            if e == .unauthorized { return "Passcode was rejected. Lock and unlock again." }
            return "Could not save: \(e.message)"
        }
        return "Could not save: \(error.localizedDescription)"
    }
}

// MARK: Debug launch arguments (CI screenshots)

enum TodayDebug {
    static func value(_ name: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }

    /// `-dayOffset -1` opens on a past day.
    static let dayOffset: Int = Int(value("-dayOffset") ?? "") ?? 0
    /// `-now 2026-11-24T23:20:00-06:00` pretends it's that time (to show the made-up data's day).
    static let now: Date? = LogTime.parse(value("-now"))
    /// `-scrollTo meals` scrolls to that card.
    static let scrollTo: String? = value("-scrollTo")
    /// `-todayOpen targets|effect|checkin|month` opens that editor or sheet.
    static let open: String? = value("-todayOpen")
}

// MARK: Switching tabs

/// Selects another tab the way a tap on the tab bar does (asking the tab bar's delegate first).
@MainActor
enum TodayTabs {
    static func select(_ index: Int) {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                if let tbc = find(window.rootViewController) {
                    pick(tbc, index)
                    return
                }
            }
        }
    }

    private static func find(_ vc: UIViewController?) -> UITabBarController? {
        guard let vc else { return nil }
        if let t = vc as? UITabBarController { return t }
        for c in vc.children {
            if let t = find(c) { return t }
        }
        return nil
    }

    private static func pick(_ tbc: UITabBarController, _ index: Int) {
        guard let vcs = tbc.viewControllers, index >= 0, index < vcs.count else { return }
        let vc = vcs[index]
        if let delegate = tbc.delegate, delegate.tabBarController?(tbc, shouldSelect: vc) == false { return }
        tbc.selectedIndex = index
        tbc.delegate?.tabBarController?(tbc, didSelect: vc)
    }
}
