import SwiftUI
import CoreLocation

// MARK: - Departure cards of one stop
//
// Loading skeleton, "nothing coming" message, or one route-coloured card per
// line + direction (swipe a card for the following departures).

struct DepartureCardsList: View {
    let schedule: [ScheduleEntry]
    var isLoading: Bool = false
    /// Replaces the generic empty text when the reason is known (e.g. the
    /// network's timetable starts on a future date).
    var emptyNotice: String? = nil
    var maxCards: Int = 4
    /// Tapping a card (the swipe gesture is unaffected).
    var onTap: (() -> Void)? = nil

    var body: some View {
        let groups = schedule.groupedByRouteAndHeadsign(limit: 5)
        if isLoading && groups.isEmpty {
            RouteDepartureCardPlaceholder()
        } else if groups.isEmpty {
            Text(emptyNotice ?? String(localized: "Aucun départ prochain"))
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.sm)
        } else {
            ForEach(Array(groups.prefix(maxCards))) { group in
                RouteDepartureCard(group: group)
                    .onTapGesture { onTap?() }
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

// MARK: - A stop and its departure cards
//
// Header (stop icon, name, favourite star, distance, chevron) above the cards.
// Used by the map's nearby list and by the favourites screen.

struct StopDeparturesBlock: View {
    let stop: Stop
    let schedule: [ScheduleEntry]
    var isLoading: Bool = false
    var isFavorite: Bool = false
    var userLocation: CLLocation? = nil
    var emptyNotice: String? = nil
    /// Open the stop's full screen (header and cards both call it).
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: stop.symbolName)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.favorite)
                            .accessibilityHidden(true)
                    }
                    Text(stop.name)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let loc = userLocation {
                        Text(stop.formattedDistance(from: loc))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            DepartureCardsList(schedule: schedule, isLoading: isLoading,
                               emptyNotice: emptyNotice, onTap: onOpen)
        }
    }
}
