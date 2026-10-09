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

    var severityLevel: Int {
        let t = type.lowercased()
        if t.contains("majeur") || t.contains("urgent") { return 3 }
        if t.contains("perturbation") || t.contains("travaux") { return 2 }
        return 1
    }

    var effectIcon: String {
        switch severityLevel {
        case 3: return "exclamationmark.triangle.fill"
        case 2: return "clock.badge.exclamationmark.fill"
        default: return "info.circle.fill"
        }
    }

    var typeLabel: String { type.isEmpty ? "Avis" : type }

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
        return m == 1 ? "+1 min de retard" : "+\(m) min de retard"
    }

    /// Minor delays use the caution hue; warning/critical match alerts.
    var severityColor: Color {
        severityLevel == 1 ? Theme.caution : Theme.severityColor(level: severityLevel)
    }
}
