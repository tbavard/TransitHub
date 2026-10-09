import SwiftUI

// MARK: - Live indicator
//
// Small pulsing "radio waves" glyph marking a countdown that comes from a
// GTFS-RT prediction rather than the static timetable.

struct LiveIndicator: View {
    var color: Color = Theme.brandEnd

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(Typography.badge)
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating)
            .accessibilityLabel(Text("En direct"))
    }
}
