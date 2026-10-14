import SwiftUI

// MARK: - Route stop timeline row
//
// One stop on a route's line diagram: a continuous vertical track in the
// route color, with larger filled nodes for the origin and the terminus.
// Rows are stacked with no spacing so the track segments join up.

struct RouteStopTimelineRow: View {
    enum Position {
        case first, middle, last, only

        init(index: Int, count: Int) {
            switch (index, count) {
            case (_, 1):                  self = .only
            case (0, _):                  self = .first
            case (count - 1, _):          self = .last
            default:                      self = .middle
            }
        }
    }

    let name: String
    let position: Position
    let color: Color

    private var isEndpoint: Bool { position != .middle }

    private static let trackWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: Spacing.md) {
            // The track is drawn in the background so it spans the full row
            // height (padding included) whatever the text wraps to.
            Color.clear.frame(width: Self.trackWidth)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(name)
                    .font(isEndpoint ? Typography.body.weight(.semibold) : Typography.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                switch position {
                case .first:
                    endpointLabel("Départ")
                case .last:
                    endpointLabel("Terminus")
                case .middle, .only:
                    EmptyView()
                }
            }

            Spacer(minLength: Spacing.sm)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Spacing.m)
        .frame(minHeight: 52)
        .background(alignment: .leading) {
            track.frame(width: Self.trackWidth)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.join([
            String(format: String(localized: "a11y.stop"), name),
            position == .first ? String(localized: "a11y.origin")
                : position == .last ? String(localized: "a11y.terminus") : nil
        ]))
    }

    private func endpointLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Typography.badge)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    private var track: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(position == .first || position == .only ? Color.clear : color)
                Rectangle()
                    .fill(position == .last || position == .only ? Color.clear : color)
            }
            .frame(width: 4)

            Circle()
                .fill(isEndpoint ? color : Theme.cardBackground)
                .frame(width: isEndpoint ? 18 : 12, height: isEndpoint ? 18 : 12)
                .overlay(
                    Circle().strokeBorder(isEndpoint ? Theme.cardBackground : color,
                                          lineWidth: isEndpoint ? 4 : 3)
                )
                .shadow(color: isEndpoint ? color.opacity(0.4) : .clear, radius: 3, x: 0, y: 1)
        }
    }
}
