import SwiftUI

// MARK: - Transit route row
//
// One route+direction within a stop card: pill, headsign, next departures.
// Shared by the dashboard stop cards and the map's stop popover.

struct TransitRouteRow: View {
    let group: RouteDeparturesGroup

    var body: some View {
        content
            // One sentence: "Line 24, towards Est, in 4 minutes, in 12 minutes, live".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11y.join([
                A11y.route(group.routeShortName),
                A11y.towards(group.headsign),
                A11y.countdowns(Array(group.minutes.prefix(3))),
                group.isLive ? String(localized: "a11y.live") : nil
            ]))
    }

    private var content: some View {
        HStack(spacing: Spacing.md) {
            RoutePill(shortName: group.routeShortName, color: group.routeColor)
                .frame(width: 44)

            Text(group.headsign.isEmpty ? "—" : group.headsign)
                .font(Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Spacing.s)

            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                if group.isLive {
                    LiveIndicator()
                }
                let mins = Array(group.minutes.prefix(3))
                ForEach(mins.indices, id: \.self) { i in
                    CountdownLabel(minutes: mins[i], emphasised: i == 0)
                }
            }
        }
    }
}

// MARK: - Placeholder (loading state)

struct TransitRouteRowPlaceholder: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color(.systemFill))
                .frame(width: 44, height: 28)
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color(.systemFill))
                .frame(height: 12)
            Spacer()
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color(.systemFill))
                .frame(width: 36, height: 14)
        }
        .redacted(reason: .placeholder)
    }
}
