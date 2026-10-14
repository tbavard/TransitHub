import SwiftUI

// MARK: - Typography
//
// Named text roles so views stop hand-assembling `.font(.system(size:weight:))`.
// All roles resolve to Dynamic Type text styles.
// Countdown / numeric styles use the rounded design already established in
// CountdownLabel, keeping the transit-app numeric feel.

enum Typography {

    // Content roles — resolve to Dynamic Type styles so accessibility scaling
    // keeps working.
    static let screenTitle  = Font.largeTitle.bold()
    static let sectionTitle = Font.headline
    static let cardTitle    = Font.headline
    static let body         = Font.subheadline
    static let caption      = Font.caption
    static let badge        = Font.caption2.weight(.bold)

    // Numeric / countdown roles — rounded design for a tabular, transit feel.
    // Built on text styles (title3 ≈ 20 pt, subheadline ≈ 15 pt, caption2 ≈
    // 11 pt at the default size) so they follow Dynamic Type.
    static func countdown(emphasised: Bool) -> Font {
        .system(emphasised ? .title3 : .subheadline,
                design: .rounded,
                weight: emphasised ? .bold : .semibold)
    }

    static func countdownUnit(emphasised: Bool) -> Font {
        .system(.caption2, weight: emphasised ? .semibold : .medium)
    }

    /// Countdown beyond an hour ("1h05").
    static func countdownLong(emphasised: Bool) -> Font {
        .system(emphasised ? .callout : .footnote,
                design: .rounded,
                weight: emphasised ? .bold : .semibold)
    }

    /// Route pill number (scales with Dynamic Type; pills use
    /// minimumScaleFactor to stay inside their frame).
    static let pill = Font.subheadline.weight(.bold)
}
