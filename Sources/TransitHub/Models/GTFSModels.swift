import Foundation
import MapKit
import SwiftUI

// MARK: - Route

struct Route: Identifiable, Hashable {
    let gtfsId: String   // raw GTFS route_id (unique only within one provider)
    let agencyId: String
    let shortName: String
    let longName: String
    let type: Int        // 1=metro, 3=bus, 0=tram
    let color: String    // RRGGBB hex
    let textColor: String
    var providerId: String = "stm"

    /// Stable cross-provider identifier used by Identifiable / ForEach.
    var id: String { "\(providerId):\(gtfsId)" }

    var routeType: RouteType { RouteType(rawValue: type) ?? .bus }

    var routeColor: Color { Color(hex: color) ?? Theme.brandStart }
    var routeTextColor: Color { Color(hex: textColor) ?? .white }

    // Official STM metro line colors (overrides GTFS feed color for metro lines)
    var officialRouteColor: Color {
        guard providerId == "stm" else { return routeColor }
        switch shortName {
        case "1": return Color(hex: "EF7D00") ?? routeColor
        case "2": return Color(hex: "00A650") ?? routeColor
        case "4": return Color(hex: "0060A9") ?? routeColor
        case "5": return Color(hex: "F5D800") ?? routeColor
        default:  return routeColor
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(gtfsId)
        hasher.combine(providerId)
    }
    static func == (lhs: Route, rhs: Route) -> Bool {
        lhs.gtfsId == rhs.gtfsId && lhs.providerId == rhs.providerId
    }

    enum RouteType: Int, Codable {
        case tram = 0
        case metro = 1
        case rail = 2
        case bus = 3
        case ferry = 4
        case funicular = 7

        var icon: String {
            switch self {
            case .metro:     return "m.circle.fill"
            case .bus:       return "bus.fill"
            case .tram:      return "tram.fill"
            case .rail:      return "train.side.front.car"
            case .ferry:     return "ferry.fill"
            case .funicular: return "cablecar"
            }
        }

        var label: String {
            switch self {
            case .metro:     return String(localized: "Métro")
            case .bus:       return String(localized: "Bus")
            case .tram:      return String(localized: "Tramway")
            case .rail:      return String(localized: "Train")
            case .ferry:     return String(localized: "Traversier")
            case .funicular: return String(localized: "Funiculaire")
            }
        }
    }
}

// MARK: - Stop

struct Stop: Identifiable, Hashable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let locationType: Int    // 0=stop/platform, 1=station, 2=entrance
    let parentStation: String?
    var providerId: String = "stm"

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var isStation: Bool {
        locationType == 1 || (!(parentStation ?? "").isEmpty)
    }

    /// Stable key for persisting favorites across providers (e.g. "stm:51425")
    var favoriteKey: String { "\(providerId):\(id)" }

    func distance(from location: CLLocation) -> CLLocationDistance {
        CLLocation(latitude: lat, longitude: lon).distance(from: location)
    }

    func formattedDistance(from location: CLLocation) -> String {
        let d = distance(from: location)
        return d < 1000
            ? String(format: "%.0f m", d)
            : String(format: "%.1f km", d / 1000)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(providerId)
    }
    static func == (lhs: Stop, rhs: Stop) -> Bool {
        lhs.id == rhs.id && lhs.providerId == rhs.providerId
    }
}

// MARK: - Trip

struct Trip: Codable, Identifiable {
    let id: String
    let routeId: String
    let serviceId: String
    let headsign: String
    let directionId: Int
}

// MARK: - Schedule Entry

struct ScheduleEntry: Identifiable {
    let id = UUID()
    let departureTime: String   // HH:MM:SS (may exceed 24h for overnight service)
    let tripId: String
    let headsign: String
    let routeId: String
    let routeShortName: String
    let routeColor: String
    /// GTFS trips.direction_id. Optional so callers that don't know it
    /// (tests, legacy paths) can omit it.
    var directionId: Int? = nil
    /// stop_times.stop_sequence of this departure; lets realtime updates of
    /// earlier stops propagate their delay here.
    var stopSequence: Int? = nil
    /// Live information merged from GTFS-RT trip updates (nil = schedule only).
    var realtime: RealtimeStatus? = nil

    /// True when the feed says this departure won't happen (trip canceled or
    /// this stop skipped).
    var isCanceled: Bool { realtime == .canceled || realtime == .skipped }

    var delaySeconds: Int? {
        if case .delay(let s) = realtime { return s }
        return nil
    }

    /// Live delay rounded to the minute (negative = early, 0 = on time / unknown).
    var delayMinutes: Int {
        Int((Double(delaySeconds ?? 0) / 60).rounded())
    }

    /// Returns "HH:MM" with 24h wrap for display
    var displayTime: String {
        let parts = departureTime.split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return departureTime }
        return String(format: "%02d:%02d", h % 24, m)
    }

    /// True when departure is after midnight (GTFS time > 24:00)
    var isNextDay: Bool {
        guard let h = Int(departureTime.split(separator: ":").first ?? "") else { return false }
        return h >= 24
    }

    /// Minutes since today's midnight. GTFS times ≥ 24:00 (today's service
    /// running past midnight) land after 1440, i.e. tonight. Yesterday's
    /// overnight trips are already shifted onto today's clock by
    /// `GTFSDatabase.fetchSchedule`, so no early-morning special case is needed.
    private var scheduledMinutes: Int? {
        let parts = departureTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// Scheduled time shifted by the live delay — what countdowns and
    /// "departed" checks use (a bus due 08:00 running +5 hasn't left at 08:02).
    private var effectiveMinutes: Int? {
        scheduledMinutes.map { $0 + delayMinutes }
    }

    private static func currentMinutes() -> Int {
        let cal = Calendar.current
        let now = Date()
        return cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
    }

    /// True when the departure has already passed today.
    var hasDepartedToday: Bool {
        guard let dep = effectiveMinutes else { return true }
        return dep < Self.currentMinutes()
    }

    /// Minutes until this departure from now. Already-departed entries are
    /// treated as tomorrow's so callers can still sort them last.
    var minutesUntilDeparture: Int {
        guard let dep = effectiveMinutes else { return Int.max }
        let cur = Self.currentMinutes()
        return dep >= cur ? dep - cur : 1440 - cur + dep
    }

    /// Predicted "HH:MM" (scheduled time + live delay).
    var predictedDisplayTime: String {
        guard let dep = effectiveMinutes else { return displayTime }
        let wrapped = ((dep % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }
}

// MARK: - Realtime status

enum RealtimeStatus: Equatable {
    /// Live prediction available; seconds of delay (0 = on time, < 0 = early).
    case delay(seconds: Int)
    case canceled
    case skipped
}

// MARK: - Route departure summary

struct RouteNext: Identifiable {
    let id: String        // route short name (stable ID for ForEach)
    let shortName: String
    let color: String
    let minutes: Int
}

extension Array where Element == ScheduleEntry {
    /// Returns the soonest upcoming departure per route, sorted by minutes.
    func nextDeparturesByRoute() -> [RouteNext] {
        let groups = Dictionary(grouping: self) { $0.routeShortName }
        return groups.compactMap { shortName, entries -> RouteNext? in
            guard let entry = entries
                .filter({ !$0.hasDepartedToday && !$0.isCanceled })
                .min(by: { $0.minutesUntilDeparture < $1.minutesUntilDeparture })
            else { return nil }
            return RouteNext(id: shortName, shortName: shortName,
                             color: entry.routeColor,
                             minutes: entry.minutesUntilDeparture)
        }
        .sorted { $0.minutes < $1.minutes }
    }
}

// MARK: - Route direction group (Transit App-style row)

/// One route + one direction (headsign) at a stop, with the next N upcoming
/// departures expressed as minutes-until-departure.
struct RouteDeparturesGroup: Identifiable {
    let id: String            // "routeShortName|headsign"
    let routeShortName: String
    let routeColor: String    // RRGGBB hex
    let headsign: String
    let minutes: [Int]        // sorted ascending, already filtered to upcoming
    /// The soonest departure carries a live (GTFS-RT) prediction.
    var isLive: Bool = false
}

extension Array where Element == ScheduleEntry {
    /// Groups upcoming departures by route and headsign, returning the next
    /// `limit` departures per direction. Sorted by soonest departure.
    func groupedByRouteAndHeadsign(limit: Int = 3) -> [RouteDeparturesGroup] {
        let groups = Dictionary(grouping: self) { "\($0.routeShortName)|\($0.headsign)" }
        return groups.compactMap { key, entries -> RouteDeparturesGroup? in
            // Sorted by predicted time: with live delays, a late earlier bus
            // can arrive after an on-time later one.
            let upcoming = entries
                .filter { !$0.hasDepartedToday && !$0.isCanceled }
                .sorted { $0.minutesUntilDeparture < $1.minutesUntilDeparture }
            guard let first = upcoming.first else { return nil }
            let mins = upcoming.prefix(limit).map(\.minutesUntilDeparture)
            return RouteDeparturesGroup(
                id: key,
                routeShortName: first.routeShortName,
                routeColor: first.routeColor,
                headsign: first.headsign,
                minutes: mins,
                isLive: first.delaySeconds != nil
            )
        }
        .sorted {
            ($0.minutes.first ?? .max, $0.routeShortName) <
            ($1.minutes.first ?? .max, $1.routeShortName)
        }
    }
}

// MARK: - Stop route context

/// The line + direction the user came from when opening a stop from a route's
/// detail. When present, the stop screen shows only that line's departures.
struct StopRouteContext: Hashable {
    let route: Route
    let directionId: Int
}

/// Departures at a stop for one route in one direction.
struct StopDepartureGroup: Identifiable {
    let id: String            // "routeId|directionId"
    let routeId: String
    let routeShortName: String
    let routeColor: String
    let headsign: String      // most frequent headsign in the group
    let entries: [ScheduleEntry]  // sorted by departure time
}

extension Array where Element == ScheduleEntry {
    /// Keeps only the departures of the context route, in its direction.
    /// Falls back to the route regardless of direction when the feed doesn't
    /// populate direction_id consistently, so the user never gets an empty
    /// screen for a stop that is listed on that route.
    func filtered(for context: StopRouteContext?) -> [ScheduleEntry] {
        guard let context else { return self }
        let onRoute = filter { $0.routeId == context.route.gtfsId }
        let inDirection = onRoute.filter { $0.directionId == context.directionId }
        return inDirection.isEmpty ? onRoute : inDirection
    }

    /// Groups departures by route AND direction (two directions of the same
    /// line never share a grid), sorted naturally by route number.
    func groupedByRouteAndDirection() -> [StopDepartureGroup] {
        let groups = Dictionary(grouping: self) { "\($0.routeId)|\($0.directionId ?? -1)" }
        return groups.compactMap { key, entries -> StopDepartureGroup? in
            let sorted = entries.sorted { $0.departureTime < $1.departureTime }
            guard let first = sorted.first else { return nil }
            let headsignCounts = Dictionary(grouping: sorted, by: \.headsign).mapValues(\.count)
            let headsign = headsignCounts.max {
                ($0.value, $1.key) < ($1.value, $0.key)
            }?.key ?? first.headsign
            return StopDepartureGroup(
                id: key,
                routeId: first.routeId,
                routeShortName: first.routeShortName,
                routeColor: first.routeColor,
                headsign: headsign,
                entries: sorted
            )
        }
        .sorted {
            let order = $0.routeShortName.localizedStandardCompare($1.routeShortName)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.headsign < $1.headsign
        }
    }
}

// MARK: - GTFS time helpers

enum GTFSTime {
    /// Zero-pads a GTFS time ("8:05:00" → "08:05:00"). The spec allows a
    /// single-digit hour, but the app sorts and compares times as strings, so
    /// they must be normalized at import. Unparseable input is returned as is.
    static func normalized(_ raw: String) -> String {
        // Fast path for the common, already-padded case: this runs once per
        // stop_times row (millions on large feeds).
        let bytes = Array(raw.utf8)
        if bytes.count == 8,
           (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[0]),
           bytes[2] == UInt8(ascii: ":"), bytes[5] == UInt8(ascii: ":") {
            return raw
        }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count),
              let h = Int(parts[0]), let m = Int(parts[1]) else { return raw }
        let s = parts.count == 3 ? (Int(parts[2]) ?? 0) : 0
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Seconds since midnight of a "HH:MM[:SS]" time (HH may exceed 23).
    static func seconds(of time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)
    }

    /// "HH:MM:SS" from seconds since midnight (HH may exceed 23).
    static func format(seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// Fills nil times of one trip (ordered by stop_sequence) by linear
    /// interpolation between the nearest known times on each side. Gaps with
    /// no known time before or after stay nil. Interpolates by stop count —
    /// shape_dist_traveled would be more precise but isn't imported.
    static func interpolated(_ times: [String?]) -> [String?] {
        let secs = times.map { $0.flatMap(seconds(of:)) }
        var out = times
        var lastKnown: Int? = nil
        for (i, value) in secs.enumerated() {
            guard let b = value else { continue }
            if let l = lastKnown, i - l > 1, let a = secs[l] {
                for k in (l + 1)..<i {
                    out[k] = format(seconds: a + (b - a) * (k - l) / (i - l))
                }
            }
            lastKnown = i
        }
        return out
    }

    /// Moves an after-midnight time of the previous service day onto today's
    /// clock ("25:10:00" → "01:10:00"). nil for times before 24:00.
    static func shiftedFromPreviousDay(_ time: String) -> String? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] >= 24 else { return nil }
        return String(format: "%02d:%02d:%02d", parts[0] - 24, parts[1], parts.count > 2 ? parts[2] : 0)
    }
}

/// Service IDs relevant right now: today's, plus yesterday's — whose
/// after-midnight trips (GTFS times ≥ 24:00) still run this morning.
struct ActiveServices {
    let today: [String]
    let yesterday: [String]
}

// MARK: - Service Calendar

struct ServiceCalendar: Codable {
    let serviceId: String
    let monday: Bool
    let tuesday: Bool
    let wednesday: Bool
    let thursday: Bool
    let friday: Bool
    let saturday: Bool
    let sunday: Bool
    let startDate: String
    let endDate: String
}

// `Color(hex:)` now lives in Sources/Shared/Color+Hex.swift (shared by the
// app and widget targets).
