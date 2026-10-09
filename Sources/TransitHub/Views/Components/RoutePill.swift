import SwiftUI

// MARK: - Route pill
//
// The colored route-number badge (e.g. metro line "1", bus "80"). Shared by
// the dashboard, trip planner and stop detail views.

struct RoutePill: View {
    let shortName: String
    let color: String
    /// Wins over `color` (e.g. official STM metro colors from `Route`).
    var colorOverride: Color? = nil

    private var tint: Color { colorOverride ?? Color(hex: color) ?? Theme.brandStart }

    var body: some View {
        Text(shortName)
            .font(Typography.pill)
            .foregroundStyle(tint.readableForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.s)
            .frame(minWidth: 40)
            .background(tint.livelyGradient,
                        in: RoundedRectangle(cornerRadius: Radius.sm))
            .accessibilityLabel(A11y.route(shortName))
    }
}

extension RoutePill {
    /// Pill for a known route, using its official color when it has one.
    init(route: Route) {
        self.init(shortName: route.shortName, color: route.color,
                  colorOverride: route.officialRouteColor)
    }
}
