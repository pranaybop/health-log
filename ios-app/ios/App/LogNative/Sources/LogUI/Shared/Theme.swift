import SwiftUI
import UIKit

/// Colors from ios-app/www/styles.css, light and dark. Use these, not raw colors, so the native
/// screens match the rest of the app. Series colors s1-s4 are the chart palette (validated for
/// color-blind separation); status colors are only for good / watch / bad states, with a label.
public enum LogColor {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    public static let bg = dyn(0xF2F2F7, 0x000000)
    public static let surface = dyn(0xFFFFFF, 0x16181D)
    public static let surface2 = dyn(0xF2F3F7, 0x22252C)
    public static let ink = dyn(0x10131A, 0xF2F3F5)
    public static let ink2 = dyn(0x5D6472, 0x9BA1AC)
    public static let hairline = dyn(0xE3E5EA, 0x2A2D34)
    public static let grid = dyn(0xECEEF2, 0x24272D)
    public static let axis = dyn(0xC6CAD2, 0x3B3F47)
    public static let accent = dyn(0x1B64BE, 0x2370CD)
    public static let link = dyn(0x1B64BE, 0x6AABF1)
    public static let accentSoft = dyn(0xE6EFFB, 0x15253C)
    public static let s1 = dyn(0x257DE0, 0x338CED)
    public static let s2 = dyn(0xF47230, 0xE76624)
    public static let s3 = dyn(0x6A4CE2, 0x9887EF)
    public static let s4 = dyn(0x00B894, 0x00A888)
    public static let good = dyn(0x0AAC23, 0x0AAC23)
    public static let goodInk = dyn(0x006C10, 0x53C556)
    public static let goodSoft = dyn(0xE3F5E6, 0x10291A)
    public static let warn = dyn(0xFBB315, 0xFBB315)
    public static let warnInk = dyn(0x8A5A00, 0xFBB315)
    public static let warnSoft = dyn(0xFDF1D6, 0x2E2410)
    public static let crit = dyn(0xDC3C3D, 0xDC3C3D)
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
    public static let logCardTitle = Font.system(size: 20, weight: .bold, design: .rounded)
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
