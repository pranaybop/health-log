import SwiftUI
import LogCore

/// Injection sites (web: renderSiteMap): a front-view drawing with the six rotation sites, the
/// legend, when each site was last used, and the suggested next site.
struct MLSitesCard: View {
    let data: Dashboard

    var body: some View {
        let rot = Analytics.siteRotation(data)
        LogCard("Injection sites") {
            MLSiteMap(rot: rot)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity)
            HStack(spacing: 14) {
                legend(.next, "Suggested next")
                legend(.last, "Last used")
                legend(.used, "Used before")
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                ForEach(Array(Sites.all.enumerated()), id: \.offset) { i, s in
                    if i > 0 { MLHairline() }
                    row(s, rot)
                }
            }
            Caption("Front view: your right side is on the left of the drawing.")
        }
    }

    private func row(_ s: String, _ rot: SiteRotation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(MLFmt.site(s)).font(.subheadline).foregroundStyle(LogColor.ink)
            if s == rot.next { MLBadge("Next", .good) } else if s == rot.lastSite { MLBadge("Last", .steady) }
            Spacer(minLength: 8)
            Text(rot.lastUsed[s].map(MLFmt.day) ?? "Not used yet")
                .font(.subheadline).foregroundStyle(LogColor.ink2)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ state: MLSiteState, _ label: String) -> some View {
        HStack(spacing: 5) {
            MLSiteDotKey(state: state).frame(width: 10, height: 10)
            Text(label).font(.footnote).foregroundStyle(LogColor.ink2).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

enum MLSiteState { case next, last, used, unused }

struct MLSiteDotKey: View {
    let state: MLSiteState
    var body: some View {
        switch state {
        case .next: Circle().fill(LogColor.good)
        case .last: Circle().fill(LogColor.surface).overlay(Circle().strokeBorder(LogColor.s1, lineWidth: 2.5))
        case .used: Circle().fill(LogColor.s1.opacity(0.3))
        case .unused: Circle().strokeBorder(LogColor.axis, lineWidth: 1.5)
        }
    }
}

/// The web's 240 x 200 site map, scaled to the width it gets.
struct MLSiteMap: View {
    let rot: SiteRotation
    static let positions: [String: CGPoint] = [
        "Abd UR": CGPoint(x: 94, y: 84), "Abd UL": CGPoint(x: 146, y: 84),
        "Abd LR": CGPoint(x: 94, y: 140), "Abd LL": CGPoint(x: 146, y: 140),
        "Love R": CGPoint(x: 62, y: 118), "Love L": CGPoint(x: 178, y: 118),
    ]

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / 240
            ZStack(alignment: .topLeading) {
                MLTorsoShape().fill(LogColor.surface2)
                MLTorsoShape().stroke(LogColor.hairline, lineWidth: 1.5)
                MLRibsShape().stroke(LogColor.hairline, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                Circle().fill(LogColor.axis).frame(width: 6 * k, height: 6 * k).position(x: 120 * k, y: 112 * k)
                Text("R").font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(LogColor.ink2)
                    .position(x: 22 * k, y: 57 * k)
                Text("L").font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(LogColor.ink2)
                    .position(x: 218 * k, y: 57 * k)
                ForEach(Sites.all, id: \.self) { s in
                    dot(s, k)
                }
            }
        }
        .aspectRatio(240.0 / 200.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Injection site map, front view of the abdomen")
        .accessibilityValue(rot.next.map { "Suggested next: \(MLFmt.site($0))" } ?? "")
    }

    private func state(_ s: String) -> MLSiteState {
        if s == rot.next { return .next }
        if s == rot.lastSite { return .last }
        if rot.lastUsed[s] != nil { return .used }
        return .unused
    }

    @ViewBuilder
    private func dot(_ s: String, _ k: CGFloat) -> some View {
        let p = Self.positions[s] ?? .zero
        let st = state(s)
        let short = s.replacingOccurrences(of: "Abd ", with: "").replacingOccurrences(of: "Love ", with: "")
        ZStack {
            switch st {
            case .next:
                Circle().fill(LogColor.good)
                Circle().stroke(LogColor.surface, lineWidth: 3 * k)
            case .last:
                Circle().fill(LogColor.surface)
                Circle().stroke(LogColor.s1, lineWidth: 3 * k)
            case .used:
                Circle().fill(LogColor.surface)
                Circle().fill(LogColor.s1.opacity(0.3))
            case .unused:
                Circle().fill(LogColor.surface)
                Circle().stroke(LogColor.axis, lineWidth: 1.5 * k)
            }
            Text(short)
                .font(.system(size: 10.5 * k, weight: .semibold))
                .foregroundStyle(st == .next ? Color.white : (st == .unused ? LogColor.ink2 : LogColor.ink))
        }
        .frame(width: 30 * k, height: 30 * k)
        .position(x: p.x * k, y: p.y * k)
    }
}

/// Ribcage to hips, in the web drawing's 240 x 200 space.
struct MLTorsoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 240
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var p = Path()
        p.move(to: pt(58, 6))
        p.addCurve(to: pt(182, 6), control1: pt(88, -2), control2: pt(152, -2))
        p.addCurve(to: pt(180, 104), control1: pt(190, 36), control2: pt(188, 70))
        p.addCurve(to: pt(196, 198), control1: pt(174, 132), control2: pt(186, 162))
        p.addLine(to: pt(44, 198))
        p.addCurve(to: pt(60, 104), control1: pt(54, 162), control2: pt(66, 132))
        p.addCurve(to: pt(58, 6), control1: pt(52, 70), control2: pt(50, 36))
        p.closeSubpath()
        return p
    }
}

struct MLRibsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 240
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 76 * k, y: rect.minY + 30 * k))
        p.addQuadCurve(to: CGPoint(x: rect.minX + 164 * k, y: rect.minY + 30 * k),
                       control: CGPoint(x: rect.minX + 120 * k, y: rect.minY + 52 * k))
        return p
    }
}
