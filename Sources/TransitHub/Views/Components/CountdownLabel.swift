import SwiftUI

// MARK: - Countdown label
//
// Shows minutes-until-departure with urgency coloring. Emphasised for the very
// next departure. Falls back to "1h05" style beyond an hour.

struct CountdownLabel: View {
    let minutes: Int
    var emphasised: Bool = false

    var body: some View {
        content
            // Read as "in 4 minutes" rather than "4", "min".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11y.countdown(minutes))
            // Digits roll instead of snapping when the minute ticks over.
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: minutes)
    }

    @ViewBuilder
    private var content: some View {
        if minutes < 60 {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                Text(minutes == 0 ? "•" : "\(minutes)")
                    .font(Typography.countdown(emphasised: emphasised))
                    .monospacedDigit()
                if minutes > 0 {
                    Text("min")
                        .font(Typography.countdownUnit(emphasised: emphasised))
                        .opacity(0.7)
                } else {
                    Text("countdown.now_short")
                        .font(Typography.countdownUnit(emphasised: emphasised))
                }
            }
            .foregroundStyle(emphasised ? Theme.urgencyColor(forMinutes: minutes) : .secondary)
        } else {
            let h = minutes / 60
            let m = minutes % 60
            Text(m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))")
                .font(Typography.countdownLong(emphasised: emphasised))
                .monospacedDigit()
                .foregroundStyle(emphasised ? Theme.urgencyColor(forMinutes: minutes) : .secondary)
        }
    }
}
