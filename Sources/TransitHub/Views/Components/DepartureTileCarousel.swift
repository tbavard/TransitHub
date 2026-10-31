import SwiftUI

// MARK: - Departure tile carousel
//
// Transit-style row of departure tiles for one line + direction at a stop:
// the next departure is a tile in the line's colour with a pointer underneath,
// the following ones are white tiles with the number in the line's colour, and
// departures that come from the timetable only (no live data) are greyed and
// tagged "Horaire". Swipe to see more.

struct DepartureTileCarousel: View {
    /// Upcoming departures, soonest first.
    let entries: [ScheduleEntry]
    let tint: Color
    /// Not read directly: changing it every minute re-renders the countdowns.
    let now: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.m) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    DepartureTile(entry: entry, tint: tint, isNext: index == 0)
                }
            }
            .scrollTargetLayout()
            .padding(.bottom, Spacing.s)   // room for the first tile's pointer
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

private struct DepartureTile: View {
    let entry: ScheduleEntry
    let tint: Color
    let isNext: Bool

    private var minutes: Int { entry.minutesUntilDeparture }
    private var isLive: Bool { entry.delaySeconds != nil }

    /// A colour that stays readable on white: very light line colours (yellow)
    /// fall back to the primary text colour.
    private var numberColor: Color {
        if isNext { return tint.readableForeground }
        if !isLive { return .secondary }
        return tint.readableForeground == .white ? tint : .primary
    }

    private var digits: String {
        if minutes == 0 { return "•" }
        if minutes < 60 { return "\(minutes)" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
    }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                if isLive { LiveIndicator(color: numberColor) }
                Text(digits)
                    .font(Typography.bigMinutes)
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
            }
            if minutes < 60 {
                (minutes == 0 ? Text("countdown.imminent") : Text("minutes"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isNext ? tint.readableForeground.opacity(0.9) : Color.secondary)
            }
            if !isLive {
                Text("Horaire")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xxs)
                    .background(Color(.systemGray), in: Capsule())
            }
        }
        .frame(width: 112, height: 108)
        .background(background)
        .overlay(alignment: .bottom) {
            if isNext {
                // The pointer under the first tile.
                Triangle()
                    .fill(tint)
                    .frame(width: 20, height: 9)
                    .offset(y: 8)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.join([
            A11y.countdown(minutes),
            A11y.liveStatus(of: entry) ?? String(localized: "Horaire")
        ]))
    }

    @ViewBuilder
    private var background: some View {
        if isNext {
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .fill(tint.livelyGradient)
                .shadow(color: tint.opacity(0.3), radius: 6, x: 0, y: 3)
        } else {
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .fill(Theme.cardBackground)
                .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
