import ActivityKit
import SwiftUI

// Shared between the main app (starts the activity) and the widget extension (renders it).

struct DepartureAttributes: ActivityAttributes {

    // Dynamic state — updated as the vehicle approaches
    struct ContentState: Codable, Hashable {
        var minutesUntilDeparture: Int
        var isDelayed: Bool
        var statusMessage: String
    }

    // Static info — fixed at activity creation
    let routeShortName: String
    let routeColor: String    // RRGGBB hex
    let headsign: String
    let stopName: String
}
