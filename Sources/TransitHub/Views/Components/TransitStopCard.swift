import SwiftUI
import CoreLocation

// MARK: - Transit stop card
//
// A single stop with its upcoming departures grouped by route/direction.
// Shared by the dashboard ("Mes arrêts") and the Nearby tab.

struct TransitStopCard: View {
    let stop: Stop
    let schedule: [ScheduleEntry]
    let userLocation: CLLocation?
    var isFavorite: Bool = false
    var isLoading: Bool = false
    var maxRoutes: Int = 5
    /// Replaces "No active service" when the reason is known (e.g. the
    /// network's timetable only starts on a future date).
    var emptyNotice: String? = nil

    private var emptyText: Text {
        if schedule.isEmpty, let emptyNotice { return Text(verbatim: emptyNotice) }
        return Text(schedule.isEmpty ? "Aucun service actif" : "Aucun départ prochain")
    }

    private var groups: [RouteDeparturesGroup] { schedule.groupedByRouteAndHeadsign(limit: 3) }

    // Divider inset so it starts after the pill column (14 pad + 44 pill + 12 gap).
    private let rowDividerInset: CGFloat = Spacing.lg + 44 + Spacing.md

    var body: some View {
        content.favoriteFeedback(isFavorite)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.m)

            if isLoading {
                Divider().padding(.leading, Spacing.lg)
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        TransitRouteRowPlaceholder()
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.m)
                        if i < 2 { Divider().padding(.leading, rowDividerInset) }
                    }
                }
            } else if groups.isEmpty {
                Divider().padding(.leading, Spacing.lg)
                emptyText
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.lg)
            } else {
                Divider().padding(.leading, Spacing.lg)
                VStack(spacing: 0) {
                    let shown = Array(groups.prefix(maxRoutes))
                    ForEach(shown.indices, id: \.self) { i in
                        TransitRouteRow(group: shown[i])
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.m)
                        if i < shown.count - 1 {
                            Divider().padding(.leading, rowDividerInset)
                        }
                    }
                    if groups.count > maxRoutes {
                        HStack {
                            Text("+ \(groups.count - maxRoutes) autre(s) ligne(s)")
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
                    }
                }
            }
        }
        .card(elevated: isFavorite)
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: Spacing.xs - 1) {
                HStack(spacing: Spacing.s) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.favorite)
                    }
                    Text(stop.name)
                        .font(Typography.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                HStack(spacing: Spacing.s) {
                    ProviderBadge(providerId: stop.providerId)
                    if let loc = userLocation {
                        Text(stop.formattedDistance(from: loc))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: Spacing.xs)

            Image(systemName: "chevron.right")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
