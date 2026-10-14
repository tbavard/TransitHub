import Foundation

// MARK: - Recently viewed routes
//
// Stored as newline-joined `Route.id` values ("providerId:gtfsId") in a single
// @AppStorage string, so both the route detail (writer) and the Lines list
// (reader) stay in sync without an extra store object.

enum RecentRoutes {
    static let storageKey = "recent_route_ids"
    static let limit = 5

    static func ids(from raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    /// Moves `id` to the front, dropping duplicates and anything past `limit`.
    static func adding(_ id: String, to raw: String, limit: Int = limit) -> String {
        ([id] + ids(from: raw).filter { $0 != id })
            .prefix(limit)
            .joined(separator: "\n")
    }
}
