import Foundation
import CoreLocation
import Combine
import os

@MainActor
final class AppViewModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.transithub", category: "AppViewModel")

    // MARK: - Dependencies

    let providersStore: UserProvidersStore
    private var providerSubscription: AnyCancellable?
    private var iCloudObserver: NSObjectProtocol?

    init(providersStore: UserProvidersStore) {
        self.providersStore = providersStore
        // Reload GTFS only when the provider SET changes (add/remove). Ignore
        // metadata-only edits like renaming the short name, otherwise each
        // keystroke in Settings would kick off a fresh download.
        providerSubscription = providersStore.$providers
            .map { $0.map(\.id).sorted() }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.loadData()
            }

        // Subscribe to iCloud key-value store external changes so favorites sync
        // across devices. Safe if the entitlement isn't granted — the KVS just
        // stays empty and we fall back to UserDefaults.
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.mergeFavoritesFromiCloud(note: note)
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    deinit {
        if let obs = iCloudObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Loading state

    @Published var isLoading = true
    @Published var loadingProgress: Double = 0
    @Published var loadingMessage = String(localized: "loading.initializing")
    @Published var loadingError: Error?

    // MARK: - Static GTFS data

    @Published var routes: [Route] = []
    @Published var stops:  [Stop]  = []
    @Published var todayServiceIds: [String] = []

    // MARK: - Real-time data

    @Published var serviceAlerts:    [ServiceAlert]    = []
    @Published var routeDelays:      [RouteDelay]      = []
    @Published var vehiclePositions: [VehiclePosition] = []
    @Published var isRefreshingRealtime = false
    @Published var realtimeError: Error?

    // MARK: - User location (synced from LocationService in MainTabView)

    @Published var userLocation: CLLocation? = nil

    // MARK: - Favorites
    // Keys are stored as "providerId:stopId" (e.g. "mdb-2126:51425").

    @Published var favoriteStopIds: Set<String> = []

    private let favoritesKey = "favorite_stop_ids"

    var favoriteStops: [Stop] {
        favoriteStopIds.compactMap { key in stops.first { $0.favoriteKey == key } }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Derived helpers

    var metroRoutes: [Route] { routes.filter { $0.routeType == .metro } }
    var busRoutes:   [Route] { routes.filter { $0.routeType == .bus   } }

    func nearestStops(to location: CLLocation, count: Int = 10) -> [Stop] {
        stops
            .map { ($0, $0.distance(from: location)) }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
            .map { $0.0 }
    }

    func stopsInRegion(centerLat: Double, centerLon: Double,
                       latDelta: Double, lonDelta: Double,
                       max: Int = 300) -> [Stop] {
        let minLat = centerLat - latDelta
        let maxLat = centerLat + latDelta
        let minLon = centerLon - lonDelta
        let maxLon = centerLon + lonDelta
        return stops.lazy
            .filter { $0.lat >= minLat && $0.lat <= maxLat &&
                      $0.lon >= minLon && $0.lon <= maxLon }
            .prefix(max)
            .map { $0 }
    }

    // MARK: - Schedules

    /// Loads the next departures for every stop, grouped by provider to minimise DB open/close cycles.
    func loadSchedules(for stops: [Stop]) async -> [String: [ScheduleEntry]] {
        guard !stops.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            let byProvider = Dictionary(grouping: stops, by: \.providerId)
            var result: [String: [ScheduleEntry]] = [:]
            for (pid, provStops) in byProvider {
                let db = GTFSDatabase.forProviderId(pid)
                try? db.open()
                defer { db.close() }
                let sids = (try? db.fetchActiveServiceIds()) ?? []
                for stop in provStops {
                    result[stop.id] = (try? db.fetchSchedule(stopId: stop.id, serviceIds: sids)) ?? []
                }
            }
            return result
        }.value
    }

    func fetchSchedule(for stop: Stop) async throws -> [ScheduleEntry] {
        let pid = stop.providerId
        let stopId = stop.id
        return try await Task.detached(priority: .userInitiated) {
            let db = GTFSDatabase.forProviderId(pid)
            try db.open()
            defer { db.close() }
            let serviceIds = try db.fetchActiveServiceIds()
            return try db.fetchSchedule(stopId: stopId, serviceIds: serviceIds)
        }.value
    }

    // MARK: - Trip planning

    /// Plans direct (single-vehicle) trips between origin and destination. MVP — no transfers.
    func planTrip(
        from origin: PlanEndpoint,
        to destination: PlanEndpoint,
        departAt: Date = Date()
    ) async throws -> [TripItinerary] {
        let snapshotStops = stops
        let loc = userLocation
        return try await TripPlanner.planDirect(
            from: origin,
            to: destination,
            allStops: snapshotStops,
            userLocation: loc,
            departAt: departAt
        )
    }

    // MARK: - Favorites management

    func toggleFavorite(_ stop: Stop) {
        let key = stop.favoriteKey
        if favoriteStopIds.contains(key) {
            favoriteStopIds.remove(key)
        } else {
            favoriteStopIds.insert(key)
        }
        saveFavorites()
    }

    func isFavorite(_ stop: Stop) -> Bool { favoriteStopIds.contains(stop.favoriteKey) }

    private func saveFavorites() {
        let arr = Array(favoriteStopIds)
        UserDefaults.standard.set(arr, forKey: favoritesKey)
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(arr, forKey: favoritesKey)
        kvs.synchronize()
    }

    private func loadFavorites() {
        // Prefer iCloud KVS (cross-device) when it has any value stored; fall
        // back to the local UserDefaults mirror otherwise. Either way, we then
        // migrate any legacy bare-ID entries from the single-provider era and
        // re-save so both stores end up with the canonical "providerId:stopId"
        // form.
        let kvs = NSUbiquitousKeyValueStore.default
        let remote = kvs.array(forKey: favoritesKey) as? [String]
        let local  = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        let combined = Set(remote ?? []).union(local)
        let migrated = Self.migrateLegacyFavoriteKeys(combined)
        favoriteStopIds = migrated
        if migrated != combined || remote == nil {
            saveFavorites()
        }
    }

    /// Merge favorites from an external iCloud notification with the local set
    /// (union), so adding on another device doesn't erase favorites added here
    /// while offline.
    private func mergeFavoritesFromiCloud(note: Notification) {
        let userInfo = note.userInfo ?? [:]
        let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        guard changedKeys.contains(favoritesKey) else { return }
        let remote = NSUbiquitousKeyValueStore.default.array(forKey: favoritesKey) as? [String] ?? []
        let merged = favoriteStopIds.union(remote)
        let migrated = Self.migrateLegacyFavoriteKeys(merged)
        guard migrated != favoriteStopIds else { return }
        favoriteStopIds = migrated
        // Write back so the device that originated this change also ends up
        // with the union (prevents "lose my offline additions" scenarios).
        saveFavorites()
    }

    /// Upgrade any bare-ID entries (legacy single-provider format) to the
    /// namespaced "providerId:stopId" form. Unknown legacy IDs are attributed
    /// to STM since it was the only provider before multi-provider support.
    nonisolated static func migrateLegacyFavoriteKeys(_ keys: Set<String>) -> Set<String> {
        Set(keys.map { $0.contains(":") ? $0 : "stm:\($0)" })
    }

    // MARK: - Realtime refresh

    func refreshRealtime() async {
        let realtimeProviders = providersStore.providers.filter {
            $0.supportsRealtime &&
            GTFSRealtimeService.forProvider($0).hasAPIKey
        }
        guard !realtimeProviders.isEmpty else { return }

        isRefreshingRealtime = true
        realtimeError = nil

        var mergedVehicles: [VehiclePosition] = []
        var mergedDelays:   [RouteDelay]      = []
        var mergedAlerts:   [ServiceAlert]    = []
        var firstError: Error? = nil

        for provider in realtimeProviders {
            let service = GTFSRealtimeService.forProvider(provider)

            async let vehiclesTask = service.fetchVehiclePositions()
            async let updatesTask  = service.fetchTripUpdates()
            async let alertsTask   = service.fetchServiceAlerts()

            do {
                mergedVehicles += try await vehiclesTask
            } catch {
                firstError = firstError ?? error
            }
            do {
                let updates = try await updatesTask
                mergedDelays += await service.computeRouteDelays(from: updates)
            } catch {
                firstError = firstError ?? error
            }
            do {
                mergedAlerts += try await alertsTask
            } catch {
                Self.logger.warning("[\(provider.shortName, privacy: .public)] alerts fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        vehiclePositions = mergedVehicles
        routeDelays      = mergedDelays.sorted { $0.avgDelaySeconds > $1.avgDelaySeconds }
        serviceAlerts    = mergedAlerts.sorted { $0.severityLevel > $1.severityLevel }
        realtimeError    = firstError

        updateWidgetSnapshots()
        isRefreshingRealtime = false
    }

    // MARK: - Widget snapshot update

    func updateWidgetSnapshots() {
        guard !favoriteStops.isEmpty else { return }
        let stops = Array(favoriteStops.prefix(3))
        Task.detached(priority: .background) {
            let byProvider = Dictionary(grouping: stops, by: \.providerId)
            var snapshots: [DepartureSnapshot] = []
            let now = Date()
            for (pid, provStops) in byProvider {
                let db = GTFSDatabase.forProviderId(pid)
                try? db.open()
                defer { db.close() }
                let sids = (try? db.fetchActiveServiceIds()) ?? []
                for stop in provStops {
                    let entries = (try? db.fetchSchedule(stopId: stop.id, serviceIds: sids)) ?? []
                    let snapshotEntries = entries.prefix(6).map { e in
                        DepartureSnapshot.SnapshotEntry(
                            id:             UUID().uuidString,
                            minutesFromNow: e.minutesUntilDeparture,
                            routeShortName: e.routeShortName,
                            headsign:       e.headsign,
                            routeColor:     e.routeColor
                        )
                    }
                    snapshots.append(DepartureSnapshot(
                        id:        stop.id,
                        stopName:  stop.name,
                        updatedAt: now,
                        entries:   Array(snapshotEntries)
                    ))
                }
            }
            SharedDataStore.saveSnapshots(snapshots)
        }
    }

    // MARK: - Data loading

    func loadData() {
        Task {
            await performLoad()
        }
    }

    private func performLoad() async {
        isLoading = true
        loadingError = nil
        loadFavorites()

        let providers = providersStore.providers

        // Empty-state path — nothing to download, app stays idle until user adds a provider.
        guard !providers.isEmpty else {
            routes = []
            stops = []
            todayServiceIds = []
            loadingProgress = 1.0
            loadingMessage = String(localized: "loading.add_provider")
            isLoading = false
            return
        }

        do {
            var allRoutes: [Route] = []
            var allStops:  [Stop]  = []

            for (i, provider) in providers.enumerated() {
                let baseP  = Double(i) / Double(providers.count)
                let scale  = 1.0       / Double(providers.count)
                let pid    = provider.id
                let pShort = provider.shortName

                let update: @Sendable (Double, String) -> Void = { [weak self] p, msg in
                    Task { @MainActor [weak self] in
                        self?.loadingProgress = baseP + p * scale
                        self?.loadingMessage  = "[\(pShort)] \(msg)"
                    }
                }

                let service = GTFSService.forProvider(provider)
                let isFresh = await Task.detached { service.isDatabaseFresh() }.value
                if !isFresh {
                    try await Task.detached {
                        try await service.downloadAndImport(onProgress: update)
                    }.value
                }

                loadingMessage = String(format: String(localized: "loading.lines"), provider.shortName)
                let (provRoutes, provStops) = try await Task.detached(priority: .userInitiated) {
                    let db = GTFSDatabase.forProviderId(pid)
                    try db.open()
                    defer { db.close() }
                    return (try db.fetchRoutes(), try db.fetchStops())
                }.value

                allRoutes += provRoutes
                allStops  += provStops
            }

            routes = allRoutes
            stops  = allStops

            // Pre-load today's service IDs for the first realtime-capable provider
            // (only used by the STM realtime path today; harmless if empty).
            if let rtProvider = providers.first(where: { $0.supportsRealtime }) {
                let pid = rtProvider.id
                todayServiceIds = (try? await Task.detached(priority: .userInitiated) {
                    let db = GTFSDatabase.forProviderId(pid)
                    try db.open()
                    defer { db.close() }
                    return try db.fetchActiveServiceIds()
                }.value) ?? []
            } else {
                todayServiceIds = []
            }

            loadingProgress = 1.0
            loadingMessage  = String(localized: "loading.ready")
            isLoading = false

        } catch {
            loadingError = error
            isLoading = false
        }
    }
}
