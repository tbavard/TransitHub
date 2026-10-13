import Foundation
import CoreLocation
import SwiftUI

// MARK: - Vehicle Position

struct VehiclePosition: Identifiable, Codable {
    let id: String
    let routeId: String
    let tripId: String
    let lat: Double
    let lon: Double
    let bearing: Float
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Trip Update (real-time delay info per trip)

struct TripUpdate: Identifiable {
    let id: String          // trip_id
    let routeId: String
    let vehicleId: String
    let stopTimeUpdates: [StopTimeUpdate]
    let timestamp: Date
    /// Trip CANCELED / DELETED in the feed.
    var isCanceled: Bool = false
}

struct StopTimeUpdate {
    let stopId: String
    let stopSequence: Int
    let arrivalDelay: Int?    // seconds (negative = early)
    let departureDelay: Int?  // seconds
    let arrivalTime: Date?
    let departureTime: Date?
    /// Stop SKIPPED by this trip (the vehicle will not serve it).
    var isSkipped: Bool = false
}

// MARK: - Service Alert (from État du Service REST API)

struct ServiceAlert: Identifiable {
    let id: String
    let title: String
    let body: String
    let type: String        // e.g. "Perturbation", "Travaux", "Information"
    let affectedRouteIds: [String]
    let affectedStopCodes: [String]
    let fetchedAt: Date
    /// GTFS-RT cause / effect enum case names ("construction", "detour"…),
    /// nil for the STM JSON feed which only has free-text types.
    var cause: String? = nil
    var effect: String? = nil
    /// Feed-provided severity_level (1 info, 2 warning, 3 severe), if any.
    var feedSeverity: Int? = nil

    /// 1 info, 2 warning, 3 critical. Prefers the feed's own severity, then
    /// the effect (what riders experience), then the STM free-text heuristic.
    var severityLevel: Int {
        if let feedSeverity { return feedSeverity }
        switch effect {
        case "noService":
            return 3
        case "reducedService", "significantDelays", "detour", "stopMoved", "modifiedService":
            return 2
        default:
            break
        }
        let t = type.lowercased()
        if t.contains("majeur") || t.contains("urgent") { return 3 }
        if t.contains("perturbation") || t.contains("travaux") { return 2 }
        return 1
    }

    var effectIcon: String { Self.icon(forSeverity: severityLevel) }

    static func icon(forSeverity level: Int) -> String {
        switch level {
        case 3: return "exclamationmark.triangle.fill"
        case 2: return "clock.badge.exclamationmark.fill"
        default: return "info.circle.fill"
        }
    }

    /// Human label: the effect ("Détour") when meaningful, else the cause
    /// ("Travaux"), else the feed's free text — never a raw enum name.
    var typeLabel: String {
        if let effect, let label = Self.localizedLabel("alert.effect.\(effect)") { return label }
        if let cause, let label = Self.localizedLabel("alert.cause.\(cause)") { return label }
        if type.isEmpty || type == cause || type == effect { return String(localized: "alert.generic") }
        return type
    }

    /// nil when the key has no translation (unknown / uninformative values
    /// such as "unknownCause" are deliberately left out of the tables).
    private static func localizedLabel(_ key: String) -> String? {
        let value = NSLocalizedString(key, comment: "")
        return value == key ? nil : value
    }

    /// Same palette as the rest of the app (Theme), not the stock system hues.
    var severityColor: Color { Theme.severityColor(level: severityLevel) }
}

// MARK: - Route Delay (derived from TripUpdates — used in Alerts tab)

struct RouteDelay: Identifiable {
    let id: String          // route_id
    let routeId: String
    let avgDelaySeconds: Int
    let delayedTripCount: Int
    let totalTripCount: Int

    var delayMinutes: Int { avgDelaySeconds / 60 }

    var severityLevel: Int {
        switch avgDelaySeconds {
        case 600...: return 3   // ≥ 10 min → critical
        case 300...: return 2   // ≥ 5 min  → warning
        default:     return 1   // ≥ 2 min  → info
        }
    }

    var effectIcon: String {
        switch severityLevel {
        case 3: return "exclamationmark.triangle.fill"
        case 2: return "clock.badge.exclamationmark.fill"
        default: return "clock.fill"
        }
    }

    var delayLabel: String {
        let m = delayMinutes
        return m == 1 ? String(localized: "+1 min de retard") : String(localized: "+\(m) min de retard")
    }

    /// Minor delays use the caution hue; warning/critical match alerts.
    var severityColor: Color {
        severityLevel == 1 ? Theme.caution : Theme.severityColor(level: severityLevel)
    }
}
