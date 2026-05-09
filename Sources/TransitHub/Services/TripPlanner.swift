import Foundation
import CoreLocation

/// Direct-trip planner (MVP — no transfers).
///
/// Strategy:
/// 1. Resolve origin + destination to a small cluster of nearby stops (walking distance)
///    so the user doesn't have to pick the exact stop on the correct street side.
/// 2. Query GTFS for trips that visit an origin stop and later a destination stop on
///    the same vehicle (single JOIN on stop_times by trip_id).
/// 3. For each candidate trip, prepend a walk leg from the user/origin to the boarding
///    stop, and append a walk leg from the alighting stop to the destination.
/// 4. Sort by arrival time at destination, dedupe by route+headsign, keep top N.
///
/// Multi-provider: if endpoints are served by different providers we plan each
/// side per-provider and return the earliest arriving results. Transfers between
/// providers are out of scope for this MVP.
enum TripPlanner {

    // MARK: - Tunables

    /// Max walking radius from either endpoint to a candidate boarding/alighting stop.
    static let walkRadiusMeters: Double = 600

    /// Max walking stops considered on each side (closest first).
    static let maxStopsPerEndpoint: Int = 8

    /// Max itineraries returned.
    static let resultLimit: Int = 8

    /// Max raw trip candidates pulled from DB per provider before post-filtering.
    static let dbRowLimit: Int = 40

    // MARK: - Resolution

    /// A resolved endpoint: either a concrete coordinate with a cluster of nearby stops,
    /// or the caller-picked stop with its neighbours as alternates.
    private struct ResolvedEndpoint {
        let coordinate: CLLocationCoordinate2D
        let displayName: String
        /// Candidate stops grouped by provider id → ordered by walking distance.
        let stopsByProvider: [String: [Stop]]
    }

    private static func resolve(
        _ endpoint: PlanEndpoint,
        userLocation: CLLocation?,
        allStops: [Stop]
    ) throws -> ResolvedEndpoint {
        switch endpoint {
        case .userLocation:
            guard let loc = userLocation else { throw TripPlanError.noLocationAvailable }
            let nearby = stopsNear(coordinate: loc.coordinate, in: allStops)
            return ResolvedEndpoint(
                coordinate: loc.coordinate,
                displayName: String(localized: "plan.my_location"),
                stopsByProvider: Dictionary(grouping: nearby, by: \.providerId)
            )

        case .stop(let stop):
            // Include the chosen stop + its close neighbours so we can catch trips
            // that only serve the "other side of the street" stop.
            var cluster = stopsNear(coordinate: stop.coordinate, in: allStops)
            if !cluster.contains(where: { $0.favoriteKey == stop.favoriteKey }) {
                cluster.insert(stop, at: 0)
            }
            return ResolvedEndpoint(
                coordinate: stop.coordinate,
                displayName: stop.name,
                stopsByProvider: Dictionary(grouping: cluster, by: \.providerId)
            )
        }
    }

    private static func stopsNear(
        coordinate: CLLocationCoordinate2D,
        in allStops: [Stop]
    ) -> [Stop] {
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return allStops
            .map { ($0, $0.distance(from: center)) }
            .filter { $0.1 <= walkRadiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(maxStopsPerEndpoint)
            .map { $0.0 }
    }

    // MARK: - Planning entry point

    /// Runs the direct-trip search. Safe to call from a detached task —
    /// it opens and closes per-provider DB handles internally.
    static func planDirect(
        from origin: PlanEndpoint,
        to destination: PlanEndpoint,
        allStops: [Stop],
        userLocation: CLLocation?,
        departAt: Date
    ) async throws -> [TripItinerary] {

        if origin == destination { throw TripPlanError.sameEndpoint }

        let resolvedOrigin      = try resolve(origin,      userLocation: userLocation, allStops: allStops)
        let resolvedDestination = try resolve(destination, userLocation: userLocation, allStops: allStops)

        // Intersect providers: a direct trip can only happen if both endpoints
        // are served by the same provider.
        let commonProviders = Set(resolvedOrigin.stopsByProvider.keys)
            .intersection(resolvedDestination.stopsByProvider.keys)
        guard !commonProviders.isEmpty else { throw TripPlanError.noRouteFound }

        let depTimeStr = gtfsTimeString(from: departAt)

        var allItineraries: [TripItinerary] = []

        for providerId in commonProviders {
            guard let fromStops = resolvedOrigin.stopsByProvider[providerId],
                  let toStops   = resolvedDestination.stopsByProvider[providerId] else { continue }

            let rows = await fetchRowsDetached(
                providerId: providerId,
                fromStopIds: fromStops.map(\.id),
                toStopIds:   toStops.map(\.id),
                afterTime:   depTimeStr
            )

            let byId: [String: Stop] = Dictionary(uniqueKeysWithValues:
                (fromStops + toStops).map { ($0.id, $0) }
            )

            let originCoord = resolvedOrigin.coordinate
            let destCoord   = resolvedDestination.coordinate
            let originName  = resolvedOrigin.displayName
            let destName    = resolvedDestination.displayName

            for row in rows {
                guard let fromStop = byId[row.fromStopId],
                      let toStop   = byId[row.toStopId] else { continue }

                let walkTo = WalkLeg(
                    fromName:       originName,
                    toName:         fromStop.name,
                    fromCoordinate: originCoord,
                    toCoordinate:   fromStop.coordinate,
                    distanceMeters: distance(originCoord, fromStop.coordinate)
                )
                let walkFrom = WalkLeg(
                    fromName:       toStop.name,
                    toName:         destName,
                    fromCoordinate: toStop.coordinate,
                    toCoordinate:   destCoord,
                    distanceMeters: distance(toStop.coordinate, destCoord)
                )
                let transit = TransitLeg(
                    providerId:     providerId,
                    routeId:        row.routeId,
                    routeShortName: row.routeShortName,
                    routeLongName:  row.routeLongName,
                    routeColor:     row.routeColor,
                    headsign:       row.headsign,
                    fromStop:       fromStop,
                    toStop:         toStop,
                    departureTime:  row.departureTime,
                    arrivalTime:    row.arrivalTime,
                    tripId:         row.tripId,
                    numStops:       row.stopCount
                )

                var legs: [TripLeg] = []
                if walkTo.distanceMeters > 15 { legs.append(.walk(walkTo)) }
                legs.append(.transit(transit))
                if walkFrom.distanceMeters > 15 { legs.append(.walk(walkFrom)) }

                let departure = absoluteDate(for: row.departureTime, reference: departAt)
                                    .addingTimeInterval(-Double(walkTo.walkMinutes * 60))
                let arrival = absoluteDate(for: row.arrivalTime, reference: departAt)
                                    .addingTimeInterval(Double(walkFrom.walkMinutes * 60))

                allItineraries.append(TripItinerary(
                    legs: legs,
                    departureDate: departure,
                    arrivalDate: arrival
                ))
            }
        }

        guard !allItineraries.isEmpty else { throw TripPlanError.noRouteFound }

        // Dedupe by (route + headsign + fromStop): we only want the soonest trip
        // of each "option" so the results list isn't flooded by the next 10 buses.
        var seen: Set<String> = []
        let deduped = allItineraries
            .sorted { $0.arrivalDate < $1.arrivalDate }
            .filter { itin in
                guard let t = itin.transitLegs.first else { return false }
                let key = "\(t.providerId)|\(t.routeShortName)|\(t.headsign)|\(t.fromStop.id)"
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
            .prefix(resultLimit)

        return Array(deduped)
    }

    // MARK: - DB glue

    private static func fetchRowsDetached(
        providerId: String,
        fromStopIds: [String],
        toStopIds:   [String],
        afterTime:   String
    ) async -> [GTFSDatabase.DirectTripRow] {
        await Task.detached(priority: .userInitiated) {
            let db = GTFSDatabase.forProviderId(providerId)
            do {
                try db.open()
                defer { db.close() }
                let services = (try? db.fetchActiveServiceIds()) ?? []
                guard !services.isEmpty else { return [] }
                return (try? db.fetchDirectTrips(
                    fromStopIds: fromStopIds,
                    toStopIds:   toStopIds,
                    serviceIds:  services,
                    afterTime:   afterTime,
                    limit:       dbRowLimit
                )) ?? []
            } catch {
                return []
            }
        }.value
    }

    // MARK: - Time helpers

    /// Renders a Date as the GTFS HH:MM:SS format used by stop_times.
    static func gtfsTimeString(from date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d",
                      comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
    }

    /// Resolves a GTFS time string (possibly >24:00 for overnight trips) to an
    /// absolute Date anchored on the same calendar day as `reference`.
    static func absoluteDate(for gtfsTime: String, reference: Date) -> Date {
        let parts = gtfsTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return reference }
        let hour = parts[0]
        let minute = parts[1]
        let second = parts.count >= 3 ? parts[2] : 0

        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: reference)
        let offset = hour * 3600 + minute * 60 + second
        return startOfDay.addingTimeInterval(TimeInterval(offset))
    }

    private static func distance(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
