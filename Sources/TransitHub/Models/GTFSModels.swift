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

    var routeColor: Color { Color(hex: color) ?? .blue }
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
            case .metro:     return "Métro"
            case .bus:       return "Bus"
            case .tram:      return "Tramway"
            case .rail:      return "Train"
            case .ferry:     return "Traversier"
            case .funicular: return "Funiculaire"
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

    /// True when the departure has already passed for today's service window.
    /// Handles GTFS overnight times (HH ≥ 24) which belong to the next calendar day.
    var hasDepartedToday: Bool {
        let parts = departureTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return true }
        let cal = Calendar.current
        let now = Date()
        let curMins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let rawHour = parts[0]
        if rawHour >= 24 {
            // Overnight GTFS time: the trip runs past midnight into the next day.
            // Consider it departed only if the clock already passed the equivalent time
            // (i.e. we're in the early hours after midnight, past that clock time).
            let depMins = (rawHour - 24) * 60 + parts[1]
            return curMins < 12 * 60 && depMins < curMins
        }
        // Normal same-day departure: simply compare clock times.
        return rawHour * 60 + parts[1] < curMins
    }

    /// Minutes until this departure from now.
    /// Returns a large value for already-departed entries so callers can still sort them last.
    var minutesUntilDeparture: Int {
        let parts = departureTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return Int.max }
        let cal = Calendar.current
        let now = Date()
        let curMins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let rawHour = parts[0]
        if rawHour >= 24 {
            // Overnight: actual clock time is (rawHour-24):mm
            let depMins = (rawHour - 24) * 60 + parts[1]
            if curMins <= depMins { return depMins - curMins }       // still ahead (after midnight)
            return 1440 - curMins + depMins                          // evening → tomorrow
        }
        let depMins = rawHour * 60 + parts[1]
        if depMins >= curMins { return depMins - curMins }           // future today
        return 1440 - curMins + depMins                              // past → treat as tomorrow
    }
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
                .sorted(by: { $0.departureTime < $1.departureTime })
                .first(where: { !$0.hasDepartedToday })
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
}

extension Array where Element == ScheduleEntry {
    /// Groups upcoming departures by route and headsign, returning the next
    /// `limit` departures per direction. Sorted by soonest departure.
    func groupedByRouteAndHeadsign(limit: Int = 3) -> [RouteDeparturesGroup] {
        let groups = Dictionary(grouping: self) { "\($0.routeShortName)|\($0.headsign)" }
        return groups.compactMap { key, entries -> RouteDeparturesGroup? in
            let upcoming = entries
                .filter { !$0.hasDepartedToday }
                .sorted { $0.departureTime < $1.departureTime }
            guard let first = upcoming.first else { return nil }
            let mins = upcoming.prefix(limit).map(\.minutesUntilDeparture)
            return RouteDeparturesGroup(
                id: key,
                routeShortName: first.routeShortName,
                routeColor: first.routeColor,
                headsign: first.headsign,
                minutes: mins
            )
        }
        .sorted {
            ($0.minutes.first ?? .max, $0.routeShortName) <
            ($1.minutes.first ?? .max, $1.routeShortName)
        }
    }
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

// MARK: - Color hex extension

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >>  8) & 0xFF) / 255.0,
            blue:  Double( rgb        & 0xFF) / 255.0
        )
    }
}
