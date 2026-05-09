import Foundation
import CoreLocation

// MARK: - Trip endpoint (user-chosen origin or destination)

enum PlanEndpoint: Equatable, Hashable {
    case userLocation
    case stop(Stop)

    var displayName: String {
        switch self {
        case .userLocation:  return String(localized: "plan.my_location")
        case .stop(let s):   return s.name
        }
    }

    var stop: Stop? {
        if case .stop(let s) = self { return s }
        return nil
    }
}

// MARK: - Trip leg (one segment of an itinerary)

struct WalkLeg: Identifiable, Hashable {
    let id = UUID()
    let fromName: String
    let toName: String
    let fromCoordinate: CLLocationCoordinate2D
    let toCoordinate: CLLocationCoordinate2D
    let distanceMeters: Double

    /// Walking time at ~80 m/min (typical pedestrian pace).
    var walkMinutes: Int { max(1, Int((distanceMeters / 80).rounded())) }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: WalkLeg, rhs: WalkLeg) -> Bool { lhs.id == rhs.id }
}

struct TransitLeg: Identifiable, Hashable {
    let id = UUID()
    let providerId: String
    let routeId: String
    let routeShortName: String
    let routeLongName: String
    let routeColor: String
    let headsign: String
    let fromStop: Stop
    let toStop: Stop
    let departureTime: String   // HH:MM:SS (may exceed 24h)
    let arrivalTime: String     // HH:MM:SS (may exceed 24h)
    let tripId: String
    let numStops: Int           // stops traversed (inclusive of both ends)

    /// Minutes the user spends aboard this vehicle.
    var onboardMinutes: Int {
        let d = Self.minutesOfDay(departureTime)
        let a = Self.minutesOfDay(arrivalTime)
        guard d != nil, let dep = d, let arr = a else { return 0 }
        let diff = arr - dep
        return diff < 0 ? diff + 1440 : diff
    }

    private static func minutesOfDay(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0] % 24) * 60 + parts[1]
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: TransitLeg, rhs: TransitLeg) -> Bool { lhs.id == rhs.id }
}

enum TripLeg: Identifiable, Hashable {
    case walk(WalkLeg)
    case transit(TransitLeg)

    var id: UUID {
        switch self {
        case .walk(let w):    return w.id
        case .transit(let t): return t.id
        }
    }
}

// MARK: - Full itinerary

struct TripItinerary: Identifiable, Hashable {
    let id = UUID()
    let legs: [TripLeg]
    let departureDate: Date    // absolute start time of first transit/walk leg
    let arrivalDate: Date      // absolute end time of last leg

    var totalMinutes: Int {
        max(1, Int(arrivalDate.timeIntervalSince(departureDate) / 60))
    }

    var transitLegs: [TransitLeg] {
        legs.compactMap { if case .transit(let t) = $0 { return t } else { return nil } }
    }

    var walkLegs: [WalkLeg] {
        legs.compactMap { if case .walk(let w) = $0 { return w } else { return nil } }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TripItinerary, rhs: TripItinerary) -> Bool { lhs.id == rhs.id }
}

// MARK: - Planning errors

enum TripPlanError: LocalizedError {
    case noOrigin
    case noDestination
    case sameEndpoint
    case noLocationAvailable
    case noRouteFound

    var errorDescription: String? {
        switch self {
        case .noOrigin:           return String(localized: "plan.error.no_origin")
        case .noDestination:      return String(localized: "plan.error.no_destination")
        case .sameEndpoint:       return String(localized: "plan.error.same_endpoint")
        case .noLocationAvailable:return String(localized: "plan.error.no_location")
        case .noRouteFound:       return String(localized: "plan.error.no_route")
        }
    }
}
