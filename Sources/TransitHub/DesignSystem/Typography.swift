import SwiftUI

// MARK: - Typography
//
// Named text roles so views stop hand-assembling `.font(.system(size:weight:))`.
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

    // Numeric / countdown roles — fixed rounded design for a tabular, transit feel.
    static func countdown(emphasised: Bool) -> Font {
        .system(size: emphasised ? 20 : 15,
                weight: emphasised ? .bold : .semibold,
                design: .rounded)
    }

    static func countdownUnit(emphasised: Bool) -> Font {
        .system(size: emphasised ? 11 : 10,
                weight: emphasised ? .semibold : .medium)
    }

    /// Route pill number.
    static let pill = Font.system(size: 14, weight: .bold)
}
