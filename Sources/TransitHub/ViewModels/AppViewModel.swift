import Foundation
import CoreLocation
import Combine
import os

@MainActor
final class AppViewModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.transithub", category: "AppViewModel")

    // MARK: - Dependencies

    let providersStore: UserProvidersStore
    private let deps: AppDependencies
    private var providerSubscription: AnyCancellable?
    private var iCloudObserver: NSObjectProtocol?

    init(providersStore: UserProvidersStore, dependencies: AppDependencies = .live) {
        self.providersStore = providersStore
        self.deps = dependencies
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

    /// First service day of each provider's feed (see `serviceNotStartedMessage`).
    @Published var serviceStartByProvider: [String: Date] = [:]

    /// "RTL schedules start on October 16." when the provider's feed only
    /// covers a future period — explains an otherwise empty schedule.
    /// nil once that day has come (or when unknown).
    func serviceNotStartedMessage(for providerId: String) -> String? {
        guard let start = serviceStartByProvider[providerId],
              start > Calendar.current.startOfDay(for: Date())
        else { return nil }
        let name = providersStore.providers.first { $0.id == providerId }?.shortName ?? providerId
        let day = start.formatted(.dateTime.day().month(.wide))
        return String(format: String(localized: "schedule.starts_on"), name, day)
    }

    /// GTFS "YYYYMMDD" → local midnight of that day.
    nonisolated static func parseServiceDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd"
        return f.date(from: s)
    }

    // MARK: - Real-time data

    @Published var serviceAlerts:    [ServiceAlert]    = []
    @Published var routeDelays:      [RouteDelay]      = []
    @Published var vehiclePositions: [VehiclePosition] = []
    /// Live trip updates per provider, keyed by trip_id — merged into stop
    /// schedules by `withRealtime(_:at:)`.
    @Published var tripUpdatesByProvider: [String: [String: TripUpdate]] = [:]
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
                let services = (try? db.fetchActiveServices()) ?? ActiveServices(today: [], yesterday: [])
                for stop in provStops {
                    result[stop.id] = (try? db.fetchSchedule(stopId: stop.id, services: services)) ?? []
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
            let services = try db.fetchActiveServices()
            return try db.fetchSchedule(stopId: stopId, services: services)
        }.value
    }

    /// Overlays the latest live trip updates on a stop's static schedule.
    /// Cheap (dictionary lookups), so views call it at render time and pick
    /// up each 30 s realtime refresh without re-querying SQLite.
    func withRealtime(_ entries: [ScheduleEntry], at stop: Stop) -> [ScheduleEntry] {
        RealtimeScheduleMerger.apply(tripUpdatesByProvider[stop.providerId] ?? [:],
                                     to: entries, stopId: stop.id)
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
        let liveTrips = tripUpdatesByProvider
        return try await TripPlanner.planDirect(
            from: origin,
            to: destination,
            allStops: snapshotStops,
            userLocation: loc,
            departAt: departAt,
            tripUpdates: liveTrips
        )
    }

    // MARK: - Favorites management

    func toggleFavorite(_ stop: Stop) {
        favoriteStopIds = FavoritesEngine.toggling(stop.favoriteKey, in: favoriteStopIds)
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
        let migrated = FavoritesEngine.loaded(remote: remote, local: local)
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
        let migrated = FavoritesEngine.merge(local: favoriteStopIds, remote: remote)
        guard migrated != favoriteStopIds else { return }
        favoriteStopIds = migrated
        // Write back so the device that originated this change also ends up
        // with the union (prevents "lose my offline additions" scenarios).
        saveFavorites()
    }

    /// Upgrade legacy bare-ID favorites to the namespaced "providerId:stopId"
    /// form. Delegates to `FavoritesEngine`; kept as a thin alias for callers
    /// (and tests) that reference it here.
    nonisolated static func migrateLegacyFavoriteKeys(_ keys: Set<String>) -> Set<String> {
        FavoritesEngine.migrateLegacyKeys(keys)
    }

    // MARK: - Realtime refresh

    func refreshRealtime() async {
        let realtimeProviders = providersStore.providers.filter {
            $0.supportsRealtime &&
            deps.realtimeService($0).hasAPIKey
        }
        guard !realtimeProviders.isEmpty else { return }

        isRefreshingRealtime = true
        realtimeError = nil

        var mergedVehicles: [VehiclePosition] = []
        var mergedDelays:   [RouteDelay]      = []
        var mergedTrips:    [String: [String: TripUpdate]] = [:]
        var mergedAlerts:   [ServiceAlert]    = []
        var firstError: Error? = nil

        for provider in realtimeProviders {
            let service = deps.realtimeService(provider)

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
                mergedTrips[provider.id] = Dictionary(updates.map { ($0.id, $0) },
                                                      uniquingKeysWith: { first, _ in first })
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
        tripUpdatesByProvider = mergedTrips
        routeDelays      = RealtimeAggregator.sortedDelays(mergedDelays)
        serviceAlerts    = RealtimeAggregator.sortedAlerts(mergedAlerts)
        realtimeError    = firstError

        updateWidgetSnapshots()
        isRefreshingRealtime = false
    }

    // MARK: - Widget snapshot update

    func updateWidgetSnapshots() {
        guard !favoriteStops.isEmpty else { return }
        let stops = Array(favoriteStops.prefix(3))
        let liveTrips = tripUpdatesByProvider
        Task.detached(priority: .background) {
            let byProvider = Dictionary(grouping: stops, by: \.providerId)
            var snapshots: [DepartureSnapshot] = []
            let now = Date()
            for (pid, provStops) in byProvider {
                let db = GTFSDatabase.forProviderId(pid)
                try? db.open()
                defer { db.close() }
                let services = (try? db.fetchActiveServices()) ?? ActiveServices(today: [], yesterday: [])
                for stop in provStops {
                    let scheduled = (try? db.fetchSchedule(stopId: stop.id, services: services)) ?? []
                    let entries = RealtimeScheduleMerger.apply(liveTrips[pid] ?? [:], to: scheduled, stopId: stop.id)
                    let snapshotEntries = entries
                        .filter { !$0.hasDepartedToday && !$0.isCanceled }
                        .sorted { $0.minutesUntilDeparture < $1.minutesUntilDeparture }
                        .prefix(6).map { e in
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

                let service = deps.gtfsService(provider)
                let isFresh = await Task.detached { service.isDatabaseFresh() }.value
                if !isFresh {
                    try await Task.detached {
                        try await service.downloadAndImport(onProgress: update)
                    }.value
                }

                loadingMessage = String(format: String(localized: "loading.lines"), provider.shortName)
                let (provRoutes, provStops, startDate) = try await Task.detached(priority: .userInitiated) {
                    let db = GTFSDatabase.forProviderId(pid)
                    try db.open()
                    defer { db.close() }
                    return (try db.fetchRoutes(), try db.fetchStops(), try? db.fetchFeedStartDate())
                }.value

                allRoutes += provRoutes
                allStops  += provStops
                serviceStartByProvider[pid] = startDate.flatMap(Self.parseServiceDate)
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
