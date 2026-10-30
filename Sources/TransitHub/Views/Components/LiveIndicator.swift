import SwiftUI

// MARK: - Live indicator
//
// Small pulsing "radio waves" glyph marking a countdown that comes from a
// GTFS-RT prediction rather than the static timetable.

struct LiveIndicator: View {
    var color: Color = Theme.urgentText
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(Typography.badge)
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityLabel(Text("En direct"))
    }
}
