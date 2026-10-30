import SwiftUI

// MARK: - Route departure card
//
// A rounded card in the line's own colour (Transit-style): big line number,
// "➜ direction" and stop name, and the next departure in very large digits.
// Swipe left/right to page through the following departures of the same line
// and direction.

struct RouteDepartureCard: View {
    let group: RouteDeparturesGroup
    /// Small line under the direction, e.g. the stop name.
    var subtitle: String = ""

    @State private var pageID: Int? = 0

    private var tint: Color { Color(hex: group.routeColor) ?? Theme.brandStart }
    private var foreground: Color { tint.readableForeground }
    private var pages: [Int] { group.minutes }
    private var currentIndex: Int { min(max(pageID ?? 0, 0), max(pages.count - 1, 0)) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, minutes in
                    page(minutes: minutes, index: index)
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageID)
        .background(tint.livelyGradient)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xxl, style: .continuous))
        .overlay(alignment: .bottom) { dots }
        .shadow(color: tint.opacity(0.25), radius: 8, x: 0, y: 4)
        // One sentence for the whole card; the later departures stay reachable
        // with the VoiceOver adjust gesture (swipe up / down).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.join([
            A11y.route(group.routeShortName),
            A11y.towards(group.headsign),
            subtitle.isEmpty ? nil : subtitle,
            A11y.countdowns(Array(pages.prefix(3))),
            group.isLive ? String(localized: "a11y.live") : nil
        ]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if currentIndex + 1 < pages.count { pageID = currentIndex + 1 }
            case .decrement: if currentIndex > 0 { pageID = currentIndex - 1 }
            @unknown default: break
            }
        }
    }

    private func page(minutes: Int, index: Int) -> some View {
        HStack(spacing: Spacing.md) {
            Text(group.routeShortName)
                .font(Typography.lineNumber)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(minWidth: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.subheadline)
                        .accessibilityHidden(true)
                    Text(group.headsign.isEmpty ? "—" : group.headsign)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.caption)
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.s)

            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    if index == 0 && group.isLive {
                        LiveIndicator(color: foreground)
                    }
                    Text(minutes == 0 ? "•" : "\(minutes)")
                        .font(Typography.bigMinutes)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
                (minutes == 0 ? Text("countdown.imminent") : Text("minutes"))
                    .font(.caption2.weight(.semibold))
                    .opacity(0.9)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .frame(minHeight: 84)
    }

    @ViewBuilder
    private var dots: some View {
        if pages.count > 1 {
            HStack(spacing: 4) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle()
                        .fill(foreground.opacity(i == currentIndex ? 0.95 : 0.35))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.bottom, Spacing.xs)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Loading placeholder

struct RouteDepartureCardPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.xxl, style: .continuous)
            .fill(Color(.systemFill))
            .frame(height: 84)
            .redacted(reason: .placeholder)
    }
}
