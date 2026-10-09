import SwiftUI

// MARK: - Route pill
//
// The colored route-number badge (e.g. metro line "1", bus "80"). Shared by
// the dashboard, trip planner and stop detail views.

struct RoutePill: View {
    let shortName: String
    let color: String

    var body: some View {
        Text(shortName)
            .font(Typography.pill)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.s)
            .frame(minWidth: 40)
            .background((Color(hex: color) ?? Theme.brandStart).livelyGradient,
                        in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}
