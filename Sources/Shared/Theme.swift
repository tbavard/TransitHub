import SwiftUI

// MARK: - Theme
//
// Central palette + gradient recipes for the "colorful & lively" direction.
// Lives in Sources/Shared so the widget extension uses the same palette.
// Views should reference `Theme.*` rather than hard-coding `.blue`, `.orange`,
// raw hex, or ad-hoc gradients, so the whole app moves together.

enum Theme {

    // MARK: Brand

    /// Primary brand hue — used for the app's identity and default accents.
    static let brandStart = Color(hex: "0A84FF") ?? .blue   // vivid blue
    /// Secondary brand hue — the "arrival / go" end of the brand gradient.
    static let brandEnd   = Color(hex: "30D158") ?? .green  // vivid green

    /// Deeper stops used only for the gradient that carries white text:
    /// white on `brandEnd` (#30D158) is ~2.0:1; on these it is >= 4.5:1.
    private static let brandGradientStart = Color(hex: "0066D6") ?? .blue
    private static let brandGradientEnd   = Color(hex: "12873A") ?? .green

    /// Signature blue → green gradient for hero headers and prominent CTAs.
    /// Always paired with white foreground text.
    static let brandGradient = LinearGradient(
        colors: [brandGradientStart, brandGradientEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Softer, low-alpha version of the brand gradient for large fills behind
    /// content that must stay legible.
    static let brandGradientSoft = LinearGradient(
        colors: [brandStart.opacity(0.18), brandEnd.opacity(0.14)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Semantic — departures urgency
    //
    // Mirrors the thresholds already used in CountdownLabel.

    /// ≤ 1 min — imminent / now.
    static let urgent  = Color(hex: "30D158") ?? .green
    /// ≤ 5 min — soon.
    static let soon    = Color(hex: "FF9F0A") ?? .orange
    /// Later — no urgency.
    static let relaxed = Color.primary

    static func urgencyColor(forMinutes minutes: Int) -> Color {
        if minutes <= 1 { return urgent }
        if minutes <= 5 { return soon }
        return relaxed
    }

    /// Text-safe variants of `urgent` / `soon`. The vivid fills are ~2:1 on a
    /// light card, so light mode uses deeper tones (>= 4.5:1); dark mode keeps
    /// the vivid ones, which read well on dark surfaces.
    static let urgentText = Color(light: Color(hex: "1E7E34") ?? .green,
                                  dark:  Color(hex: "30D158") ?? .green)
    static let soonText   = Color(light: Color(hex: "A85400") ?? .orange,
                                  dark:  Color(hex: "FF9F0A") ?? .orange)

    /// Use for countdown/delay *text*; use `urgencyColor` for fills and dots.
    static func urgencyTextColor(forMinutes minutes: Int) -> Color {
        if minutes <= 1 { return urgentText }
        if minutes <= 5 { return soonText }
        return relaxed
    }

    // MARK: Semantic — service severity
    //
    // Matches ServiceAlert/RouteDelay.severityLevel (1 info, 2 warning, 3 critical).

    static func severityColor(level: Int) -> Color {
        switch level {
        case 3:  return Color(hex: "FF453A") ?? .red     // critical
        case 2:  return Color(hex: "FF9F0A") ?? .orange  // warning
        default: return brandStart                       // info
        }
    }

    /// Network-wide status pill on the dashboard header.
    static let statusOK       = Color(hex: "30D158") ?? .green
    static let statusWarning  = Color(hex: "FF9F0A") ?? .orange
    static let statusCritical = Color(hex: "FF453A") ?? .red

    /// Minor delay / caution (yellow).
    static let caution        = Color(hex: "FFD60A") ?? .yellow

    /// Favorite star.
    static let favorite       = Color(hex: "FFD60A") ?? .yellow

    // MARK: Surfaces

    static let cardBackground      = Color(.secondarySystemGroupedBackground)
    static let screenBackground    = Color(.systemGroupedBackground)
    static let hairline            = Color(.separator)

    // MARK: Shadows — crisp, per the "colorful & lively" direction

    static let cardShadow          = Color.black.opacity(0.06)
    static let cardShadowElevated  = Color.black.opacity(0.10)
}

// MARK: - Per-provider / per-route gradient derivation
//
// Turns a single brand color into a lively two-stop gradient so provider cards
// and route pills feel vivid rather than flat, without needing a second color
// stored per provider.

extension Color {
    /// A color that resolves differently in light and dark appearance.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        self = light
        #endif
    }

    /// A gradient derived from this color: the color itself → a slightly
    /// lighter, hue-shifted variant. Deterministic, no randomness.
    var livelyGradient: LinearGradient {
        LinearGradient(
            colors: [self, self.lightened(by: 0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// White, or near-black on genuinely light colors (yellow metro line,
    /// white/pastel feed colors) where white text would be unreadable.
    /// Based on relative luminance; the threshold deliberately favors white
    /// so mid-tone brand/route colors keep the lively white-on-color look.
    var readableForeground: Color {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &alpha) else { return .white }
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.5 ? Color.black.opacity(0.85) : .white
        #else
        return .white
        #endif
    }

    /// Returns a lighter version of the color by blending toward white in the
    /// RGB space. `amount` is clamped to 0...1.
    func lightened(by amount: Double) -> Color {
        let a = min(max(amount, 0), 1)
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &alpha) else { return self }
        return Color(
            red:   Double(r) + (1 - Double(r)) * a,
            green: Double(g) + (1 - Double(g)) * a,
            blue:  Double(b) + (1 - Double(b)) * a,
            opacity: Double(alpha)
        )
        #else
        return self
        #endif
    }
}
