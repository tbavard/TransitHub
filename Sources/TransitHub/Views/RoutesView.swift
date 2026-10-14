import SwiftUI

// MARK: - Routes List

struct RoutesView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @State private var searchText = ""
    @State private var providerFilter: String? = nil  // nil = all providers
    @AppStorage(RecentRoutes.storageKey) private var recentRaw = ""

    /// Recently opened lines still loaded (a removed provider's lines drop
    /// out silently). Hidden while searching or filtering.
    private var recentRoutes: [Route] {
        guard searchText.isEmpty, providerFilter == nil else { return [] }
        let byId = Dictionary(appVM.routes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return RecentRoutes.ids(from: recentRaw).compactMap { byId[$0] }
    }

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
            .appDestinations()
        }
    }

    private var routesList: some View {
        List {
            if !recentRoutes.isEmpty {
                Section {
                    ForEach(recentRoutes) { route in
                        NavigationLink(value: AppDestination.route(route)) {
                            RouteRow(route: route)
                        }
                    }
                } header: {
                    Label("Récentes", systemImage: "clock.arrow.circlepath")
                }
            }
            ForEach(filteredRoutesByType, id: \.label) { section in
                Section(section.label) {
                    ForEach(section.routes) { route in
                        NavigationLink(value: AppDestination.route(route)) {
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
                ProviderFilterChip(label: "Tous", color: Theme.brandStart,
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
        .selectionFeedback(providerFilter)
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
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(selected ? color.readableForeground : color)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.s)
                .background(selected ? AnyShapeStyle(color.livelyGradient) : AnyShapeStyle(color.opacity(0.1)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Route Row

struct RouteRow: View {
    let route: Route

    var body: some View {
        HStack(spacing: Spacing.md) {
            RoutePill(route: route)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(route.longName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Label(route.routeType.label, systemImage: route.routeType.icon)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
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
    @AppStorage(RecentRoutes.storageKey) private var recentRaw = ""

    private var routeAlerts: [ServiceAlert] {
        appVM.serviceAlerts.filter {
            $0.affectedRouteIds.contains(route.gtfsId) ||
            $0.affectedRouteIds.contains(route.shortName)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                routeHero

                // Direction picker — labels come from trip headsigns. Only shown
                // when the route actually has multiple directions; many feeds
                // encode every trip under a single direction_id and the picker
                // would otherwise offer a dead option.
                if directionHeadsigns.count > 1 {
                    Picker("Direction", selection: $directionId.animation(.snappy)) {
                        ForEach(directionHeadsigns.keys.sorted(), id: \.self) { d in
                            Text(directionHeadsigns[d] ?? "Direction \(d)").tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .selectionFeedback(directionId)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if stops.isEmpty {
                    ContentUnavailableView(
                        "Aucun arrêt trouvé",
                        systemImage: "bus",
                        description: Text(directionHeadsigns.count > 1
                                          ? "Essayez l'autre direction."
                                          : "Cette ligne ne contient pas d'arrêts dans les données GTFS.")
                    )
                    .frame(minHeight: 300)
                } else {
                    if !routeAlerts.isEmpty {
                        alertsSection
                    }
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SectionHeader(title: "Arrêts", icon: "mappin.and.ellipse",
                                      color: route.officialRouteColor)
                        stopsTimeline
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
            // Cross-fade between loading, empty and the new direction's stops.
            .animation(.easeInOut(duration: 0.2), value: isLoading)
        }
        .background(Theme.screenBackground)
        .navigationTitle("Ligne \(route.shortName)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recentRaw = RecentRoutes.adding(route.id, to: recentRaw) }
        .task(id: directionId) {
            await loadStops()
        }
    }

    // MARK: Hero header — the route's own gradient

    private var routeHero: some View {
        let tint = route.officialRouteColor
        let fg = tint.readableForeground
        return HStack(spacing: Spacing.lg) {
            Text(route.shortName)
                .font(.system(.title, design: .rounded).weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, Spacing.sm)
                .frame(minWidth: 56, minHeight: 56)
                .background(fg.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.lg))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(route.longName)
                    .font(Typography.cardTitle)
                    .lineLimit(2)
                HStack(spacing: Spacing.s) {
                    Label(route.routeType.label, systemImage: route.routeType.icon)
                        .font(Typography.caption.weight(.semibold))
                        .opacity(0.9)
                    ProviderBadge(providerId: route.providerId)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(fg)
        .padding(Spacing.lg)
        .background(tint.livelyGradient, in: RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: tint.opacity(0.35), radius: 10, x: 0, y: 6)
    }

    // MARK: Alerts

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Avis de service", icon: "exclamationmark.triangle.fill",
                          color: Theme.statusWarning)
            ForEach(routeAlerts) { alert in
                RouteAlertRow(alert: alert)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(cornerRadius: Radius.lg)
            }
        }
    }

    // MARK: Stops timeline

    private var stopsTimeline: some View {
        let context = StopRouteContext(route: route, directionId: directionId)
        return VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                NavigationLink(value: AppDestination.stop(stop, context: context)) {
                    RouteStopTimelineRow(
                        name: stop.name,
                        position: .init(index: index, count: stops.count),
                        color: route.officialRouteColor
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .card()
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
        appVM.stops.first { $0.id == code }?.name ?? String(format: String(localized: "a11y.stop"), code)
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
