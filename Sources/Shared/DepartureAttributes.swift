import ActivityKit
import SwiftUI

// Shared between the main app (starts the activity) and the widget extension (renders it).

struct DepartureAttributes: ActivityAttributes {

    // Dynamic state — updated as the vehicle approaches
    struct ContentState: Codable, Hashable {
        var minutesUntilDeparture: Int
        var isDelayed: Bool
        var statusMessage: String

        // The static attributes below describe the first ride. After a
        // transfer the app fills these in so the same activity shows the
        // second ride (nil = keep the static value).
        var routeShortName: String? = nil
        var routeColor: String? = nil
        var headsign: String? = nil
        var stopName: String? = nil
    }

    // Static info — fixed at activity creation
    let routeShortName: String
    let routeColor: String    // RRGGBB hex
    let headsign: String
    let stopName: String
}
