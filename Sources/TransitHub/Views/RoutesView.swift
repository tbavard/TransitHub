import SwiftUI

// MARK: - Routes List

struct RoutesView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @State private var searchText = ""
    @State private var providerFilter: String? = nil  // nil = all providers

    // All route types present across loaded providers, in display order.
    private static let displayOrder: [Route.RouteType] = [.metro, .rail, .tram, .bus, .ferry, .funicular]

    var filteredRoutesByType: [(label: String, routes: [Route])] {
        Self.displayOrder.compactMap { type in
            let routes = filter(appVM.routes.filter { $0.routeType == type })
            return routes.isEmpty ? nil : (type.label, routes)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if providersStore.providers.isEmpty {
                    NoProvidersView()
                } else {
                    routesList
                }
            }
            .navigationTitle("Lignes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteDetailView(route: route)
            }
        }
    }

    private var routesList: some View {
        List {
            ForEach(filteredRoutesByType, id: \.label) { section in
                Section(section.label) {
                    ForEach(section.routes) { route in
                        NavigationLink(value: route) {
                            RouteRow(route: route)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Rechercher une ligne")
        .safeAreaInset(edge: .top, spacing: 0) {
            if providersStore.providers.count > 1 {
                providerFilterStrip
            }
        }
    }

    private var providerFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ProviderFilterChip(label: "Tous", color: .secondary,
                                   selected: providerFilter == nil) {
                    providerFilter = nil
                }
                ForEach(providersStore.providers) { p in
                    ProviderFilterChip(label: p.shortName,
                                       color: p.brandColor,
                                       selected: providerFilter == p.id) {
                        providerFilter = (providerFilter == p.id) ? nil : p.id
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func filter(_ routes: [Route]) -> [Route] {
        var result = routes
        if let pid = providerFilter {
            result = result.filter { $0.providerId == pid }
        }
        guard !searchText.isEmpty else { return result }
        let q = searchText.lowercased()
        return result.filter {
            $0.shortName.lowercased().contains(q) ||
            $0.longName.lowercased().contains(q)
        }
    }
}

private struct ProviderFilterChip: View {
    let label: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? color : color.opacity(0.1),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Route Row

struct RouteRow: View {
    let route: Route

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(route.officialRouteColor)
                    .frame(width: 48, height: 32)
                Text(route.shortName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(route.routeTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(route.longName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(route.routeType.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Route Detail

struct RouteDetailView: View {
    @EnvironmentObject var appVM: AppViewModel
    let route: Route

    @State private var directionId = 0
    @State private var directionHeadsigns: [Int: String] = [:]
    @State private var stops: [Stop] = []
    @State private var isLoading = true
    @State private var selectedStop: Stop?

    private var routeAlerts: [ServiceAlert] {
        appVM.serviceAlerts.filter {
            $0.affectedRouteIds.contains(route.gtfsId) ||
            $0.affectedRouteIds.contains(route.shortName)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Route header
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(route.officialRouteColor)
                    Text(route.shortName)
                        .font(.title2.bold())
                        .foregroundStyle(route.routeTextColor)
                }
                .frame(width: 56, height: 36)

                VStack(alignment: .leading) {
                    Text(route.longName)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(route.routeType.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProviderBadge(providerId: route.providerId)
                    }
                }
                Spacer()
            }
            .padding()
            .background(Color(.systemGroupedBackground))

            // Direction picker — labels come from trip headsigns. Only shown
            // when the route actually has multiple directions; many feeds
            // encode every trip under a single direction_id and the picker
            // would otherwise offer a dead option.
            if directionHeadsigns.count > 1 {
                Picker("Direction", selection: $directionId) {
                    ForEach(directionHeadsigns.keys.sorted(), id: \.self) { d in
                        Text(directionHeadsigns[d] ?? "Direction \(d)").tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
            }

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stops.isEmpty {
                ContentUnavailableView(
                    "Aucun arrêt trouvé",
                    systemImage: "bus",
                    description: Text(directionHeadsigns.count > 1
                                      ? "Essayez l'autre direction."
                                      : "Cette ligne ne contient pas d'arrêts dans les données GTFS.")
                )
            } else {
                List {
                    if !routeAlerts.isEmpty {
                        Section {
                            ForEach(routeAlerts) { alert in
                                RouteAlertRow(alert: alert)
                            }
                        } header: {
                            Label("Avis de service (\(routeAlerts.count))",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Arrêts") {
                        ForEach(stops) { stop in
                            Button {
                                selectedStop = stop
                            } label: {
                                HStack {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(route.routeColor)
                                    Text(stop.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Ligne \(route.shortName)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedStop) { stop in
            NavigationStack {
                StopDetailView(stop: stop)
            }
        }
        .task(id: directionId) {
            await loadStops()
        }
    }

    private func loadStops() async {
        isLoading = true
        let routeId = route.gtfsId
        let pid = route.providerId
        let dir = directionId
        let needsHeadsigns = directionHeadsigns.isEmpty

        // On first load, resolve which direction_id values this route actually
        // uses before fetching stops. GTFS feeds outside STM frequently populate
        // only one direction per route (often direction_id=1, or leave it blank
        // so it lands on the default 0). If the currently selected direction has
        // no trips, hop to the first one that does — otherwise the user sees
        // "Aucun arrêt trouvé" even though the route has stops.
        if needsHeadsigns {
            let fetchedHeadsigns = await Task.detached(priority: .userInitiated) {
                let db = GTFSDatabase.forProviderId(pid)
                try? db.open()
                defer { db.close() }
                return (try? db.fetchDirectionHeadsigns(routeId: routeId)) ?? [:]
            }.value
            directionHeadsigns = fetchedHeadsigns
            if !fetchedHeadsigns.isEmpty, !fetchedHeadsigns.keys.contains(dir),
               let fallback = fetchedHeadsigns.keys.sorted().first {
                directionId = fallback   // re-triggers .task(id: directionId)
                return
            }
        }

        let fetchedStops = await Task.detached(priority: .userInitiated) {
            let db = GTFSDatabase.forProviderId(pid)
            try? db.open()
            defer { db.close() }
            return (try? db.fetchStopsForRoute(routeId, direction: dir)) ?? []
        }.value

        stops = fetchedStops
        isLoading = false
    }
}

// MARK: - Route Alert Row

struct RouteAlertRow: View {
    @EnvironmentObject var appVM: AppViewModel
    let alert: ServiceAlert

    private func stopLabel(for code: String) -> String {
        appVM.stops.first { $0.id == code }?.name ?? "Arrêt \(code)"
    }

    var body: some View {
        let color = alert.severityColor
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.effectIcon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                // Type badge
                Text(alert.typeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.12), in: Capsule())

                // Title
                Text(alert.title)
                    .font(.subheadline.weight(.medium))

                // Affected stops chips
                if !alert.affectedStopCodes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(alert.affectedStopCodes.prefix(6), id: \.self) { code in
                                HStack(spacing: 4) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.caption2)
                                    Text(stopLabel(for: code))
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color(.systemFill), in: Capsule())
                            }
                            if alert.affectedStopCodes.count > 6 {
                                Text("+\(alert.affectedStopCodes.count - 6)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // Body
                if !alert.body.isEmpty {
                    Text(alert.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
