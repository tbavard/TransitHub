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

        var color: Color { Color(hex: routeColor) ?? .blue }
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

// MARK: - Re-export Color hex for Shared target

extension Color {
    init?(hexShared: String) {
        let hex = hexShared.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
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
