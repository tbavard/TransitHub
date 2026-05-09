import Foundation
import SwiftProtobuf
import os

// MARK: - GTFS-RT Service
//
// One instance per TransitProvider. Uses URLs + auth info baked into the
// provider record (populated by MobilityDatabase). The per-provider
// realtime API key is persisted under `rt_apikey_<providerId>`.

final class GTFSRealtimeService {

    private static let logger = Logger(subsystem: "com.transithub", category: "GTFSRealtime")

    // MARK: - Factory

    private static let lock = NSLock()
    private static var instances: [String: GTFSRealtimeService] = [:]

    static func forProvider(_ provider: TransitProvider) -> GTFSRealtimeService {
        lock.lock(); defer { lock.unlock() }
        if let existing = instances[provider.id] {
            // Refresh cached record in case URLs/auth were updated via Settings.
            existing.provider = provider
            return existing
        }
        let new = GTFSRealtimeService(provider: provider)
        instances[provider.id] = new
        return new
    }

    // MARK: - State

    private(set) var provider: TransitProvider
    private init(provider: TransitProvider) { self.provider = provider }

    private var apiKeyDefaultsKey: String { "rt_apikey_\(provider.id)" }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyDefaultsKey) }
    }

    /// True when the feed either requires no auth or a key is already stored.
    var hasAPIKey: Bool {
        if provider.rtAuthType == 0 { return true }
        return !apiKey.isEmpty
    }

    // MARK: - Connection status

    enum ConnectionStatus {
        case idle
        case testing
        case success(vehicleCount: Int)
        case failure(String)

        var isSuccess: Bool { if case .success = self { return true }; return false }
        var isFailure: Bool { if case .failure = self { return true }; return false }
    }

    func testConnection() async -> ConnectionStatus {
        guard hasAPIKey else { return .failure("Aucune clé enregistrée") }
        guard provider.rtVehiclePositionsURL != nil else {
            return .failure("Aucun flux temps réel configuré")
        }
        do {
            let vehicles = try await fetchVehiclePositions()
            return .success(vehicleCount: vehicles.count)
        } catch GTFSError.downloadError(let msg) {
            if msg.contains("401") || msg.contains("403") {
                return .failure("Clé invalide ou accès refusé (HTTP \(msg))")
            }
            return .failure(msg)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Public fetch

    func fetchVehiclePositions() async throws -> [VehiclePosition] {
        guard let url = provider.rtVehiclePositionsURL else { return [] }
        let data = try await fetchProtobuf(from: url)
        return try decodeVehiclePositions(data)
    }

    func fetchTripUpdates() async throws -> [TripUpdate] {
        guard let url = provider.rtTripUpdatesURL else { return [] }
        let data = try await fetchProtobuf(from: url)
        return try decodeTripUpdates(data)
    }

    func fetchServiceAlerts() async throws -> [ServiceAlert] {
        guard let url = provider.rtServiceAlertsURL else { return [] }
        // STM historically serves alerts as JSON on a different endpoint; other
        // providers (MobilityDatabase entries) use standard GTFS-RT protobuf.
        if provider.id == "stm" {
            let data = try await fetchJSON(from: url)
            return parseServiceAlertsJSON(data)
        } else {
            let data = try await fetchProtobuf(from: url)
            return decodeServiceAlertsProto(data)
        }
    }

    // MARK: - Route delay aggregation (from absolute departure times vs static schedule)

    func computeRouteDelays(from updates: [TripUpdate]) async -> [RouteDelay] {
        let tripsWithTime = updates.filter { u in
            u.stopTimeUpdates.contains { $0.departureTime != nil && $0.stopSequence > 0 }
        }
        guard !tripsWithTime.isEmpty else { return [] }

        let tripIds = tripsWithTime.map { $0.id }
        let pid = provider.id
        let scheduled: [String: [Int: String]]
        do {
            scheduled = try await Task.detached(priority: .userInitiated) {
                let db = GTFSDatabase.forProviderId(pid)
                try db.open()
                defer { db.close() }
                return try db.fetchScheduledDepartures(for: tripIds)
            }.value
        } catch {
            return []
        }

        struct RouteStats { var totalDelay = 0; var delayed = 0; var total = 0 }
        var byRoute: [String: RouteStats] = [:]

        for update in updates {
            let routeId = update.routeId
            guard !routeId.isEmpty else { continue }

            guard let stu = update.stopTimeUpdates.first(where: {
                      $0.departureTime != nil && $0.stopSequence > 0
                  }),
                  let predictedTime  = stu.departureTime,
                  let tripSchedule   = scheduled[update.id],
                  let timeString     = tripSchedule[stu.stopSequence],
                  let scheduledTime  = scheduledDate(from: timeString, near: predictedTime)
            else { continue }

            let delay = Int(predictedTime.timeIntervalSince(scheduledTime))
            var s = byRoute[routeId] ?? RouteStats()
            s.total += 1
            s.totalDelay += delay
            if delay >= 120 { s.delayed += 1 }
            byRoute[routeId] = s
        }

        return byRoute.compactMap { routeId, s -> RouteDelay? in
            guard s.total > 0 else { return nil }
            let avg = s.totalDelay / s.total
            guard avg >= 120 else { return nil }
            return RouteDelay(id: routeId, routeId: routeId,
                              avgDelaySeconds: avg,
                              delayedTripCount: s.delayed,
                              totalTripCount: s.total)
        }
        .sorted { $0.avgDelaySeconds > $1.avgDelaySeconds }
    }

    // Resolves "HH:MM:SS" (HH may exceed 23 for overnight trips) to a Date near `reference`.
    private func scheduledDate(from timeString: String, near reference: Date) -> Date? {
        let parts = timeString.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let seconds = TimeInterval(parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0))
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: reference)
        comps.hour = 0; comps.minute = 0; comps.second = 0
        guard let midnight = Calendar.current.date(from: comps) else { return nil }
        let candidate = midnight.addingTimeInterval(seconds)
        let diff = candidate.timeIntervalSince(reference)
        if diff >  43200 { return candidate.addingTimeInterval(-86400) }
        if diff < -43200 { return candidate.addingTimeInterval( 86400) }
        return candidate
    }

    // MARK: - Network

    private func applyAuth(to req: inout URLRequest) throws {
        switch provider.rtAuthType {
        case 0:
            return
        case 1:
            // Query-string key — already in URL if provider was configured that way,
            // but we also support it as a fallback header when the key name is known.
            if !apiKey.isEmpty, let name = provider.rtApiKeyParamName,
               var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) {
                var items = comps.queryItems ?? []
                items.removeAll { $0.name == name }
                items.append(URLQueryItem(name: name, value: apiKey))
                comps.queryItems = items
                if let newURL = comps.url { req.url = newURL }
            } else if apiKey.isEmpty {
                throw GTFSError.downloadError("Clé API manquante")
            }
        case 2:
            guard !apiKey.isEmpty else { throw GTFSError.downloadError("Clé API manquante") }
            let header = provider.rtApiKeyParamName ?? "apiKey"
            req.setValue(apiKey, forHTTPHeaderField: header)
        default:
            break
        }
    }

    private func fetchProtobuf(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        try applyAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw GTFSError.downloadError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private func fetchJSON(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        try applyAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw GTFSError.downloadError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    // MARK: - Protobuf decoders

    private func decodeVehiclePositions(_ data: Data) throws -> [VehiclePosition] {
        let feed = try TransitRealtime_FeedMessage(serializedBytes: data)
        return feed.entity.compactMap { entity -> VehiclePosition? in
            guard entity.hasVehicle else { return nil }
            let vp = entity.vehicle
            guard vp.hasPosition else { return nil }
            let pos = vp.position
            let lat = Double(pos.latitude)
            let lon = Double(pos.longitude)
            guard abs(lat) > 0.001 || abs(lon) > 0.001 else { return nil }
            let vehicleId = vp.hasVehicle ? vp.vehicle.id : entity.id
            return VehiclePosition(
                id:        vehicleId.isEmpty ? entity.id : vehicleId,
                routeId:   vp.hasTrip ? vp.trip.routeID : "",
                tripId:    vp.hasTrip ? vp.trip.tripID  : "",
                lat:       lat,
                lon:       lon,
                bearing:   pos.bearing,
                timestamp: vp.hasTimestamp ? Date(timeIntervalSince1970: Double(vp.timestamp)) : Date()
            )
        }
    }

    private func decodeTripUpdates(_ data: Data) throws -> [TripUpdate] {
        let feed = try TransitRealtime_FeedMessage(serializedBytes: data)
        return feed.entity.compactMap { entity -> TripUpdate? in
            guard entity.hasTripUpdate else { return nil }
            let tu  = entity.tripUpdate
            let tripId  = tu.hasTrip ? tu.trip.tripID  : entity.id
            let routeId = tu.hasTrip ? tu.trip.routeID : ""
            guard !tripId.isEmpty || !routeId.isEmpty else { return nil }

            let updates = tu.stopTimeUpdate.map { stu -> StopTimeUpdate in
                StopTimeUpdate(
                    stopId:         stu.stopID,
                    stopSequence:   Int(stu.stopSequence),
                    arrivalDelay:   stu.hasArrival   && stu.arrival.hasDelay   ? Int(stu.arrival.delay)   : nil,
                    departureDelay: stu.hasDeparture && stu.departure.hasDelay ? Int(stu.departure.delay) : nil,
                    arrivalTime:    stu.hasArrival   && stu.arrival.hasTime
                                        ? Date(timeIntervalSince1970: Double(stu.arrival.time))  : nil,
                    departureTime:  stu.hasDeparture && stu.departure.hasTime
                                        ? Date(timeIntervalSince1970: Double(stu.departure.time)) : nil
                )
            }
            let vehicleId = tu.hasVehicle ? tu.vehicle.id : ""
            return TripUpdate(
                id:              tripId,
                routeId:         routeId,
                vehicleId:       vehicleId,
                stopTimeUpdates: updates,
                timestamp:       tu.hasTimestamp ? Date(timeIntervalSince1970: Double(tu.timestamp)) : Date()
            )
        }
    }

    private func decodeServiceAlertsProto(_ data: Data) -> [ServiceAlert] {
        guard let feed = try? TransitRealtime_FeedMessage(serializedBytes: data) else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        return feed.entity.compactMap { entity -> ServiceAlert? in
            guard entity.hasAlert else { return nil }
            let alert = entity.alert

            // Drop alerts whose active_periods are entirely in the past.
            if !alert.activePeriod.isEmpty {
                let stillActive = alert.activePeriod.contains { ap in
                    let hasStart = ap.hasStart
                    let hasEnd   = ap.hasEnd
                    let start = hasStart ? Int(ap.start) : 0
                    let end   = hasEnd   ? Int(ap.end)   : Int.max
                    return now >= start && now <= end
                }
                if !stillActive { return nil }
            }

            let title = localized(alert.headerText)
            guard !title.isEmpty else { return nil }
            let body  = localized(alert.descriptionText)

            let cause = alert.hasCause ? "\(alert.cause)" : nil
            let effect = alert.hasEffect ? "\(alert.effect)" : nil
            let type = cause ?? effect ?? "Avis"

            let routes = alert.informedEntity.map { $0.routeID }.filter { !$0.isEmpty }
            let stops  = alert.informedEntity.map { $0.stopID  }.filter { !$0.isEmpty }

            return ServiceAlert(id: entity.id.isEmpty ? UUID().uuidString : entity.id,
                                title: title, body: body, type: type,
                                affectedRouteIds: routes, affectedStopCodes: stops,
                                fetchedAt: Date())
        }
    }

    private func localized(_ ts: TransitRealtime_TranslatedString) -> String {
        let french = ts.translation.first { $0.hasLanguage && $0.language.hasPrefix("fr") && !$0.text.isEmpty }
        return french?.text
            ?? ts.translation.first { !$0.text.isEmpty }?.text
            ?? ""
    }

    // MARK: - Service alert JSON parser (STM État du Service)

    private func parseServiceAlertsJSON(_ data: Data) -> [ServiceAlert] {
        #if DEBUG
        if let preview = String(data: data.prefix(800), encoding: .utf8) {
            Self.logger.debug("[\(self.provider.shortName, privacy: .public) Alerts] \(preview, privacy: .public)")
        }
        #endif
        guard let response = try? JSONDecoder().decode(AlertsResponse.self, from: data),
              let alerts = response.alerts
        else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        return alerts
            .compactMap { $0.toServiceAlert(relativeTo: now) }
            .sorted { $0.severityLevel > $1.severityLevel }
    }
}

// MARK: - Private JSON models for État du Service

private struct AlertsResponse: Codable {
    struct Header: Codable { let timestamp: Int? }
    let header: Header?
    let alerts: [RawAlert]?
}

private struct RawAlert: Codable {
    struct ActivePeriods: Codable {
        let start: Int?
        let end: Int?
    }
    struct InformedEntity: Codable {
        let route_short_name: String?
        let direction_id: String?
        let stop_code: String?
    }
    struct LocalizedText: Codable {
        let language: String?
        let text: String?
    }

    let active_periods: ActivePeriods?
    let cause: String?
    let effect: String?
    let informed_entities: [InformedEntity]?
    let header_texts: [LocalizedText]?
    let description_texts: [LocalizedText]?

    func toServiceAlert(relativeTo now: Int) -> ServiceAlert? {
        if let end = active_periods?.end, end < now { return nil }
        let title = preferFrench(header_texts)
        guard !title.isEmpty else { return nil }
        let body   = preferFrench(description_texts)
        let type   = cause ?? effect ?? inferType(from: body)
        let routes = (informed_entities ?? []).compactMap { $0.route_short_name }
        let stops  = (informed_entities ?? []).compactMap { $0.stop_code }.filter { !$0.isEmpty }
        return ServiceAlert(id: UUID().uuidString, title: title, body: body,
                            type: type, affectedRouteIds: routes,
                            affectedStopCodes: stops, fetchedAt: Date())
    }

    private func preferFrench(_ texts: [LocalizedText]?) -> String {
        texts?.first(where: { $0.language == "fr" && $0.text?.isEmpty == false })?.text
            ?? texts?.first(where: { $0.text?.isEmpty == false })?.text
            ?? ""
    }

    private func inferType(from text: String) -> String {
        let t = text.lowercased()
        if t.contains("travaux")                               { return "Travaux" }
        if t.contains("perturbation") || t.contains("retard") { return "Perturbation" }
        if t.contains("fermeture") || t.contains("suspension") { return "Fermeture" }
        return "Avis"
    }
}
