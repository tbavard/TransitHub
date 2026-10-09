import Foundation
import SwiftUI

// MARK: - Snapshot types (shared between app and widget extension)

struct DepartureSnapshot: Codable, Identifiable {
    let id: String       // stop id
    let stopName: String
    let updatedAt: Date
    let entries: [SnapshotEntry]

    struct SnapshotEntry: Codable, Identifiable {
        let id: String   // UUID string
        let minutesFromNow: Int   // negative means already departed
        let routeShortName: String
        let headsign: String
        let routeColor: String   // RRGGBB hex

        var color: Color { Color(hex: routeColor) ?? Theme.brandStart }
    }
}

// MARK: - Shared store

struct SharedDataStore {
    static let appGroupID       = "group.com.yourcompany.TransitHub"
    static let snapshotsKey     = "departure_snapshots_v1"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func saveSnapshots(_ snapshots: [DepartureSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults?.set(data, forKey: snapshotsKey)
    }

    static func loadSnapshots() -> [DepartureSnapshot] {
        guard let data = defaults?.data(forKey: snapshotsKey),
              let decoded = try? JSONDecoder().decode([DepartureSnapshot].self, from: data)
        else { return [] }
        return decoded
    }
}
