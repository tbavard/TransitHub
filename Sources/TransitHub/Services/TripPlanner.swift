import Foundation
import CoreLocation

/// Single-network trip planner: direct trips plus trips with ONE transfer.
///
/// Strategy:
/// 1. Resolve origin + destination to a small cluster of nearby stops (walking distance)
///    so the user doesn't have to pick the exact stop on the correct street side.
/// 2. Direct: trips that visit an origin stop and later a destination stop on the same
///    vehicle (single JOIN on stop_times by trip_id).
/// 3. One transfer: pull every segment boarding near the origin ("first legs") and every
///    segment alighting near the destination ("last legs") in a time window, then join
///    them in memory where a first leg's alighting stop is the same as — or within
///    `transferRadiusMeters` walking of — a last leg's boarding stop, with enough time
///    to walk and board.
/// 4. Prepend/append walk legs, sort by arrival, dedupe, drop transfers that a direct
///    trip beats, keep top N.
///
/// One network at a time: the caller picks the provider; stops of other providers
/// are ignored.
enum TripPlanner {

    // MARK: - Tunables

    /// Max walking radius from either endpoint to a candidate boarding/alighting stop.
    static let walkRadiusMeters: Double = 600

    /// Max walking stops considered on each side (closest first).
    static let maxStopsPerEndpoint: Int = 8

    /// Max itineraries returned.
    static let resultLimit: Int = 8

    /// Max raw trip candidates pulled from DB per direct query.
    static let dbRowLimit: Int = 40

    /// Max walk between alighting and re-boarding stops of a transfer.
    static let transferRadiusMeters: Double = 200

    /// Slack added to every transfer on top of the walk (seconds).
    static let transferBufferSeconds: Int = 120

    /// Longest wait accepted at the transfer stop (seconds).
    static let maxTransferWaitSeconds: Int = 45 * 60

    /// How far after the departure time the second leg may arrive (seconds).
    static let transferWindowSeconds: Int = 2 * 3600

    /// Row caps for the segment queries (earliest departures kept first).
    static let firstLegRowLimit: Int = 12_000
    static let lastLegRowLimit: Int = 24_000

    /// Max transfer itineraries built (each applies realtime lookups).
    static let transferItineraryLimit: Int = 12

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

    /// Runs the search on one network. Safe to call from a detached task —
    /// it opens and closes the provider's DB handle internally.
    static func plan(
        from origin: PlanEndpoint,
        to destination: PlanEndpoint,
        providerId: String,
        allStops: [Stop],
        userLocation: CLLocation?,
        departAt: Date,
        tripUpdates: [String: [String: TripUpdate]] = [:]
    ) async throws -> [TripItinerary] {

        if origin == destination { throw TripPlanError.sameEndpoint }

        let stops = allStops.filter { $0.providerId == providerId }
        let resolvedOrigin      = try resolve(origin,      userLocation: userLocation, allStops: stops)
        let resolvedDestination = try resolve(destination, userLocation: userLocation, allStops: stops)

        guard let fromStops = resolvedOrigin.stopsByProvider[providerId], !fromStops.isEmpty
        else { throw TripPlanError.noStopsNearOrigin }
        guard let toStops = resolvedDestination.stopsByProvider[providerId], !toStops.isEmpty
        else { throw TripPlanError.noStopsNearDestination }

        let data = await fetchPlanDataDetached(
            providerId:  providerId,
            fromStopIds: fromStops.map(\.id),
            toStopIds:   toStops.map(\.id),
            departAt:    departAt
        )
        let liveTrips = tripUpdates[providerId] ?? [:]
        let stopsById = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let originCoord = resolvedOrigin.coordinate
        let destCoord   = resolvedDestination.coordinate
        let originName  = resolvedOrigin.displayName
        let destName    = resolvedDestination.displayName

        // Direct trips.
        var direct: [TripItinerary] = []
        for (row, serviceDay) in data.direct {
            guard let built = buildTransitLeg(row: row, serviceDay: serviceDay, providerId: providerId,
                                              stopsById: stopsById, liveTrips: liveTrips)
            else { continue }
            let walkTo = walkLeg(fromName: originName, toName: built.leg.fromStop.name,
                                 from: originCoord, to: built.leg.fromStop.coordinate)
            let walkFrom = walkLeg(fromName: built.leg.toStop.name, toName: destName,
                                   from: built.leg.toStop.coordinate, to: destCoord)
            direct.append(assemble(walkTo: walkTo, transits: [built], transferWalk: nil, walkFrom: walkFrom))
        }

        // One-transfer trips.
        let transfers = transferItineraries(
            data: data, providerId: providerId, stops: stops, stopsById: stopsById,
            liveTrips: liveTrips, originName: originName, originCoord: originCoord,
            destName: destName, destCoord: destCoord)

        // A transfer is only worth showing if it beats every direct option.
        let bestDirectArrival = direct.map(\.arrivalDate).min()
        let usefulTransfers = transfers.filter { itin in
            guard let best = bestDirectArrival else { return true }
            return itin.arrivalDate < best
        }

        let all = direct + usefulTransfers
        guard !all.isEmpty else { throw TripPlanError.noRouteFound }

        // Dedupe by (routes + headsigns + boarding stop): we only want the soonest
        // trip of each "option" so the list isn't flooded by the next 10 buses.
        var seen: Set<String> = []
        let sorted = all.sorted { a, b in
            if a.arrivalDate != b.arrivalDate { return a.arrivalDate < b.arrivalDate }
            return a.transitLegs.count < b.transitLegs.count
        }
        var result: [TripItinerary] = []
        for itin in sorted {
            let key = itin.transitLegs
                .map { "\($0.routeShortName)|\($0.headsign)|\($0.fromStop.id)" }
                .joined(separator: ">")
            if seen.insert(key).inserted { result.append(itin) }
            if result.count >= resultLimit { break }
        }
        return result
    }

    // MARK: - One-transfer search

    /// A segment with its times as seconds since the service day's midnight.
    private struct Seg {
        let row: GTFSDatabase.DirectTripRow
        let dep: Int
        let arr: Int
    }

    private struct TransferCandidate {
        let first: Seg
        let last: Seg
        let walkMeters: Double
    }

    private static func segs(_ rows: [GTFSDatabase.DirectTripRow]) -> [Seg] {
        rows.compactMap { r in
            guard let d = GTFSTime.seconds(of: r.departureTime),
                  let a = GTFSTime.seconds(of: r.arrivalTime) else { return nil }
            return Seg(row: r, dep: d, arr: a)
        }
    }

    private static func transferItineraries(
        data: PlanData,
        providerId: String,
        stops: [Stop],
        stopsById: [String: Stop],
        liveTrips: [String: TripUpdate],
        originName: String,
        originCoord: CLLocationCoordinate2D,
        destName: String,
        destCoord: CLLocationCoordinate2D
    ) -> [TripItinerary] {
        let firsts = segs(data.first)
        var lastsByBoarding: [String: [Seg]] = [:]
        for l in segs(data.last) { lastsByBoarding[l.row.fromStopId, default: []].append(l) }
        for key in Array(lastsByBoarding.keys) {
            lastsByBoarding[key]?.sort { $0.dep < $1.dep }
        }
        guard !firsts.isEmpty, !lastsByBoarding.isEmpty else { return [] }

        let grid = StopGrid(stops: stops)
        var nearCache: [String: [(stop: Stop, meters: Double)]] = [:]

        // Best second leg per (first trip, boarding stop): earliest final arrival.
        var best: [String: TransferCandidate] = [:]
        for f in firsts {
            guard let alight = stopsById[f.row.toStopId] else { continue }
            let neighbours: [(stop: Stop, meters: Double)]
            if let cached = nearCache[alight.id] {
                neighbours = cached
            } else {
                neighbours = grid.near(alight, within: transferRadiusMeters)
                nearCache[alight.id] = neighbours
            }
            for (boardStop, meters) in neighbours {
                guard let options = lastsByBoarding[boardStop.id] else { continue }
                let ready = f.arr + Int(meters * 0.75) + transferBufferSeconds   // 80 m/min walk
                for l in options {
                    if l.dep < ready { continue }
                    if l.dep > ready + maxTransferWaitSeconds { break }
                    if l.row.tripId == f.row.tripId || l.row.routeId == f.row.routeId { continue }
                    let key = f.row.tripId + "|" + f.row.fromStopId
                    if let current = best[key], current.last.arr <= l.arr { continue }
                    best[key] = TransferCandidate(first: f, last: l, walkMeters: meters)
                }
            }
        }

        let ordered = best.values.sorted { a, b in
            if a.last.arr != b.last.arr { return a.last.arr < b.last.arr }
            return a.first.dep < b.first.dep
        }

        var seen: Set<String> = []
        var result: [TripItinerary] = []
        for c in ordered {
            if result.count >= transferItineraryLimit { break }
            let key = "\(c.first.row.routeId)|\(c.last.row.routeId)|\(c.first.row.fromStopId)|\(c.last.row.toStopId)"
            guard seen.insert(key).inserted else { continue }

            guard let b1 = buildTransitLeg(row: c.first.row, serviceDay: data.day, providerId: providerId,
                                           stopsById: stopsById, liveTrips: liveTrips),
                  let b2 = buildTransitLeg(row: c.last.row, serviceDay: data.day, providerId: providerId,
                                           stopsById: stopsById, liveTrips: liveTrips)
            else { continue }

            // Live delays may make the connection impossible.
            let walkSeconds = c.walkMeters * 0.75
            if b1.arrival.addingTimeInterval(walkSeconds + 30) > b2.departure { continue }

            let walkTo = walkLeg(fromName: originName, toName: b1.leg.fromStop.name,
                                 from: originCoord, to: b1.leg.fromStop.coordinate)
            let transferWalk = walkLeg(fromName: b1.leg.toStop.name, toName: b2.leg.fromStop.name,
                                       from: b1.leg.toStop.coordinate, to: b2.leg.fromStop.coordinate)
            let walkFrom = walkLeg(fromName: b2.leg.toStop.name, toName: destName,
                                   from: b2.leg.toStop.coordinate, to: destCoord)
            result.append(assemble(walkTo: walkTo, transits: [b1, b2],
                                   transferWalk: transferWalk, walkFrom: walkFrom))
        }
        return result
    }

    /// Spatial hash of stops for "stops within N metres" lookups.
    private struct StopGrid {
        private static let cell = 0.003   // ≈ 333 m of latitude, ≈ 235 m of longitude at 45°N
        private var cells: [Int: [Stop]] = [:]

        init(stops: [Stop]) {
            for s in stops {
                let cx = Int(floor(s.lat / StopGrid.cell))
                let cy = Int(floor(s.lon / StopGrid.cell))
                cells[StopGrid.key(cx, cy), default: []].append(s)
            }
        }

        private static func key(_ cx: Int, _ cy: Int) -> Int {
            (cx + 100_000) * 1_000_000 + (cy + 100_000)
        }

        func near(_ stop: Stop, within meters: Double) -> [(stop: Stop, meters: Double)] {
            let cx = Int(floor(stop.lat / StopGrid.cell))
            let cy = Int(floor(stop.lon / StopGrid.cell))
            let here = CLLocation(latitude: stop.lat, longitude: stop.lon)
            var out: [(stop: Stop, meters: Double)] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    for s in cells[StopGrid.key(cx + dx, cy + dy)] ?? [] {
                        let d = s.distance(from: here)
                        if d <= meters { out.append((stop: s, meters: d)) }
                    }
                }
            }
            return out
        }
    }

    // MARK: - Itinerary building

    private struct BuiltLeg {
        let leg: TransitLeg
        /// Departure / arrival including live delay.
        let departure: Date
        let arrival: Date
    }

    /// Builds one transit leg with its live-adjusted times; nil when the trip is
    /// canceled or skips the boarding/alighting stop.
    private static func buildTransitLeg(
        row: GTFSDatabase.DirectTripRow,
        serviceDay: Date,
        providerId: String,
        stopsById: [String: Stop],
        liveTrips: [String: TripUpdate]
    ) -> BuiltLeg? {
        guard let fromStop = stopsById[row.fromStopId],
              let toStop   = stopsById[row.toStopId] else { return nil }

        let scheduledDeparture = absoluteDate(for: row.departureTime, reference: serviceDay)
        let scheduledArrival   = absoluteDate(for: row.arrivalTime, reference: serviceDay)
        let boarding = RealtimeScheduleMerger.status(
            tripId: row.tripId, stopId: row.fromStopId, stopSequence: row.fromSequence,
            scheduled: scheduledDeparture, updates: liveTrips)
        let alighting = RealtimeScheduleMerger.status(
            tripId: row.tripId, stopId: row.toStopId, stopSequence: row.toSequence,
            scheduled: scheduledArrival, updates: liveTrips)
        if [boarding, alighting].contains(where: { $0 == .canceled || $0 == .skipped }) {
            return nil
        }
        let departureDelay = delaySeconds(boarding)
        let arrivalDelay   = delaySeconds(alighting) ?? departureDelay

        let leg = TransitLeg(
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
            numStops:       row.stopCount,
            liveDelaySeconds: departureDelay,
            scheduledDeparture: scheduledDeparture,
            fromStopSequence: row.fromSequence
        )
        return BuiltLeg(
            leg: leg,
            departure: scheduledDeparture.addingTimeInterval(Double(departureDelay ?? 0)),
            arrival:   scheduledArrival.addingTimeInterval(Double(arrivalDelay ?? 0)))
    }

    private static func walkLeg(
        fromName: String, toName: String,
        from: CLLocationCoordinate2D, to: CLLocationCoordinate2D
    ) -> WalkLeg {
        WalkLeg(fromName: fromName, toName: toName,
                fromCoordinate: from, toCoordinate: to,
                distanceMeters: distance(from, to))
    }

    /// Stitches walk + transit (+ transfer walk + transit) + walk into an itinerary.
    /// Walks of 15 m or less are not shown as legs and add no time.
    private static func assemble(
        walkTo: WalkLeg,
        transits: [BuiltLeg],
        transferWalk: WalkLeg?,
        walkFrom: WalkLeg
    ) -> TripItinerary {
        var legs: [TripLeg] = []
        let showWalkTo   = walkTo.distanceMeters > 15
        let showWalkFrom = walkFrom.distanceMeters > 15
        if showWalkTo { legs.append(.walk(walkTo)) }
        for (i, built) in transits.enumerated() {
            if i > 0, let w = transferWalk, w.distanceMeters > 15 { legs.append(.walk(w)) }
            legs.append(.transit(built.leg))
        }
        if showWalkFrom { legs.append(.walk(walkFrom)) }

        let departure = transits[0].departure
            .addingTimeInterval(-Double(showWalkTo ? walkTo.walkMinutes * 60 : 0))
        let arrival = transits[transits.count - 1].arrival
            .addingTimeInterval(Double(showWalkFrom ? walkFrom.walkMinutes * 60 : 0))
        return TripItinerary(legs: legs, departureDate: departure, arrivalDate: arrival)
    }

    // MARK: - DB glue

    private struct PlanData {
        /// Direct rows, each tagged with the service day its GTFS times are relative to.
        var direct: [(row: GTFSDatabase.DirectTripRow, serviceDay: Date)] = []
        var first: [GTFSDatabase.DirectTripRow] = []
        var last: [GTFSDatabase.DirectTripRow] = []
        /// Service day of `first` / `last` (the departure day).
        var day: Date
    }

    /// Everything the search needs from the provider DB, in one open/close:
    /// direct rows (the departure day's own services, plus the previous day's
    /// after-midnight trips with times ≥ 24:00), and first/last leg segments for
    /// the one-transfer search on the departure day.
    private static func fetchPlanDataDetached(
        providerId: String,
        fromStopIds: [String],
        toStopIds:   [String],
        departAt:    Date
    ) async -> PlanData {
        await Task.detached(priority: .userInitiated) { () -> PlanData in
            var data = PlanData(day: departAt)
            let db = GTFSDatabase.forProviderId(providerId)
            do {
                try db.open()
                defer { db.close() }
                let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: departAt) ?? departAt
                let afterTime = gtfsTimeString(from: departAt)
                let afterSeconds = GTFSTime.seconds(of: afterTime) ?? 0
                let afterTimeOvernight = GTFSTime.format(seconds: afterSeconds + 24 * 3600)
                let untilTime = GTFSTime.format(seconds: afterSeconds + transferWindowSeconds)

                func directRows(on day: Date, after time: String) -> [(row: GTFSDatabase.DirectTripRow, serviceDay: Date)] {
                    // Services of the planned day — not "today" — so planning
                    // for tomorrow uses tomorrow's calendar.
                    let services = (try? db.fetchActiveServiceIds(for: day)) ?? []
                    guard !services.isEmpty else { return [] }
                    let found = (try? db.fetchDirectTrips(
                        fromStopIds: fromStopIds,
                        toStopIds:   toStopIds,
                        serviceIds:  services,
                        afterTime:   time,
                        limit:       dbRowLimit
                    )) ?? []
                    return found.map { (row: $0, serviceDay: day) }
                }
                data.direct = directRows(on: departAt, after: afterTime)
                            + directRows(on: previousDay, after: afterTimeOvernight)

                let services = (try? db.fetchActiveServiceIds(for: departAt)) ?? []
                if !services.isEmpty {
                    data.first = (try? db.fetchSegments(
                        fromStopIds: fromStopIds, serviceIds: services,
                        afterTime: afterTime, untilTime: untilTime,
                        limit: firstLegRowLimit)) ?? []
                    data.last = (try? db.fetchSegments(
                        toStopIds: toStopIds, serviceIds: services,
                        afterTime: afterTime, untilTime: untilTime,
                        limit: lastLegRowLimit)) ?? []
                }
            } catch {
                return PlanData(day: departAt)
            }
            return data
        }.value
    }

    private static func delaySeconds(_ status: RealtimeStatus?) -> Int? {
        if case .delay(let s)? = status { return s }
        return nil
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
