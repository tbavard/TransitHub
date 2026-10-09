import Foundation

// MARK: - Service protocols & dependency container
//
// Abstractions over the concrete GTFS services so AppViewModel depends on
// behavior, not on the static `forProvider(_:)` factories. This is what makes
// the view model unit-testable: tests inject fakes conforming to these
// protocols instead of hitting the network / SQLite.

// MARK: Realtime

/// Fetches GTFS-Realtime data for a single provider.
protocol RealtimeFetching {
    var hasAPIKey: Bool { get }
    func fetchVehiclePositions() async throws -> [VehiclePosition]
    func fetchTripUpdates() async throws -> [TripUpdate]
    func fetchServiceAlerts() async throws -> [ServiceAlert]
    func computeRouteDelays(from updates: [TripUpdate]) async -> [RouteDelay]
}

extension GTFSRealtimeService: RealtimeFetching {}

// MARK: GTFS import / static data

/// Downloads + imports a provider's GTFS feed and reports freshness.
protocol GTFSImporting {
    func isDatabaseFresh() -> Bool
    func downloadAndImport(onProgress: @Sendable @escaping (Double, String) -> Void) async throws
}

extension GTFSService: GTFSImporting {}

// MARK: - Dependency container
//
// A single injection seam. Production wires the real factories; tests supply
// closures returning fakes. AppViewModel resolves per-provider services through
// this container rather than calling the global factories directly.

struct AppDependencies {
    var realtimeService: (TransitProvider) -> RealtimeFetching
    var gtfsService: (TransitProvider) -> GTFSImporting

    /// Production wiring — the existing singleton factories.
    static let live = AppDependencies(
        realtimeService: { GTFSRealtimeService.forProvider($0) },
        gtfsService: { GTFSService.forProvider($0) }
    )
}
