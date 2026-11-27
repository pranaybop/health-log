import SwiftUI
import UIKit

/// Colors (first taken from the web app's styles.css), light and dark. Use these, not raw colors, so the native
/// screens match the rest of the app. Series colors s1-s4 are the chart palette (validated for
/// color-blind separation); status colors are only for good / watch / bad states, with a label.
public enum LogColor {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    // Log 2.0: a soft grey-green ground, white cards, near-black ink and one teal accent.
    public static let bg = dyn(0xF3F5F2, 0x0B0F0D)
    public static let surface = dyn(0xFFFFFF, 0x171C19)
    public static let surface2 = dyn(0xF3F5F2, 0x222A26)
    public static let ink = dyn(0x142019, 0xEEF2EF)
    public static let ink2 = dyn(0x5B6660, 0x9AA6A0)
    public static let hairline = dyn(0xE3E7E3, 0x2A322E)
    public static let grid = dyn(0xEEF1EE, 0x232A26)
    public static let axis = dyn(0xC9D0CB, 0x3A4440)
    public static let accent = dyn(0x0F7A68, 0x178A74)
    public static let link = dyn(0x0F7A68, 0x5BD3B8)
    public static let accentSoft = dyn(0xDDEFEA, 0x12302A)
    /// The inverted "next dose" card (near-black in light, raised graphite in dark).
    public static let hero = dyn(0x142019, 0x222A26)
    public static let heroInk2 = dyn(0xB9C8C1, 0xA9B7B0)
    // Chart series (validated for color-blind separation, light and dark).
    public static let s1 = dyn(0x119A80, 0x2DB596)
    public static let s2 = dyn(0xD56A1F, 0xE57A30)
    public static let s3 = dyn(0x2F6FE0, 0x5B8DF0)
    public static let s4 = dyn(0xB8479A, 0xD062B4)
    public static let good = dyn(0x1F9A4A, 0x2FB862)
    public static let goodInk = dyn(0x1F6B3F, 0x5ACB7E)
    public static let goodSoft = dyn(0xE6F2EC, 0x12291C)
    public static let warn = dyn(0xE0A21A, 0xE0A21A)
    public static let warnInk = dyn(0x7A4F00, 0xF0BE4A)
    public static let warnSoft = dyn(0xFBEFD6, 0x2E2410)
    public static let crit = dyn(0xD13D3D, 0xD13D3D)
    public static let critInk = dyn(0xB42318, 0xF07167)
    public static let critSoft = dyn(0xFBE5E5, 0x331617)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Spacing and shapes from the web app's tokens.
public enum LogMetric {
    public static let gutter: CGFloat = 16
    public static let cardPad: CGFloat = 18
    public static let cardRadius: CGFloat = 22
    public static let innerRadius: CGFloat = 14
    public static let stack: CGFloat = 14
}

extension Font {
    /// SF Pro Rounded for numbers (the web app's --font-num), tabular.
    public static func logNumber(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    /// Card titles.
    public static let logCardTitle = Font.system(size: 20, weight: .bold)
}

/// Number formatting that matches the web app's fmtNum / signed.
public enum Fmt {
    private static func formatter(_ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }
    private static let cache: [NumberFormatter] = (0...3).map(formatter)

    /// 2,200 · 257.2 · "—" for nil
    public static func num(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v, v.isFinite else { return "—" }
        return cache[max(0, min(3, digits))].string(from: NSNumber(value: v)) ?? "—"
    }
    /// +1.2 · −0.4 (true minus sign) · 0.0
    public static func signed(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v, v.isFinite else { return "—" }
        let s = num(abs(v), digits)
        if s == num(0, digits) { return s }
        return v > 0 ? "+\(s)" : "−\(s)"
    }
    /// mg without a pointless ".0": 3 → "3", 2.5 → "2.5"
    public static func mg(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.rounded() == v ? num(v, 0) : num(v, 1)
    }
}
