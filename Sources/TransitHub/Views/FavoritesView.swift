import SwiftUI
import CoreLocation

struct FavoritesView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @State private var schedulesByStop: [String: [ScheduleEntry]] = [:]
    @State private var isLoadingSchedules = false
    @State private var searchText = ""
    @State private var showAlerts = false
    @State private var path = NavigationPath()

    private var searchRouteResults: [Route] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return appVM.routes.filter {
            $0.shortName.lowercased().contains(q) || $0.longName.lowercased().contains(q)
        }
    }

    private var searchStopResults: [Stop] {
        guard searchText.count >= 2 else { return [] }
        let q = searchText.lowercased()
        return Array(appVM.stops.lazy.filter {
            $0.name.lowercased().contains(q) || $0.id == searchText
        }.prefix(50))
    }

    /// Favourites, nearest first when the position is known.
    private var homeStops: [Stop] {
        if let loc = appVM.userLocation {
            return appVM.favoriteStops.sorted { $0.distance(from: loc) < $1.distance(from: loc) }
        }
        return appVM.favoriteStops
    }

    private var stopsKey: String {
        homeStops.map(\.favoriteKey).joined()
    }

    // MARK: - Header helpers

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return String(localized: "greeting.morning") }
        if h < 18 { return String(localized: "greeting.afternoon") }
        return String(localized: "greeting.evening")
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: Date()).capitalized
    }

    private var networkStatus: (icon: String, label: String, color: Color) {
        let critical = appVM.serviceAlerts.filter { $0.severityLevel >= 3 }.count
        let total    = appVM.serviceAlerts.count + appVM.routeDelays.count
        if critical > 0 {
            return ("xmark.circle.fill",
                    String(format: String(localized: "network.disruptions"), critical), Theme.statusCritical)
        }
        if total > 0 {
            return ("exclamationmark.triangle.fill",
                    String(format: String(localized: "network.alerts"), total), Theme.statusWarning)
        }
        return ("checkmark.circle.fill", String(localized: "network.normal"), Theme.statusOK)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if providersStore.providers.isEmpty {
                    NoProvidersView()
                } else if !searchText.isEmpty {
                    searchResultsView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.xxl) {
                            headerCard
                            if !appVM.serviceAlerts.isEmpty { alertsSection }
                            stopsSection
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.xxxl)
                    }
                    .background(Theme.screenBackground)
                    .refreshable {
                        await loadSchedules()
                    }
                }
            }
            .navigationTitle("Favoris")
            .searchable(text: $searchText, prompt: "Ligne, arrêt, numéro…")
            .appDestinations()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                            .accessibilityLabel(Text("Réglages"))
                    }
                }
            }
            .sheet(isPresented: $showAlerts) {
                AlertsView()
            }
        }
        .task(id: stopsKey) { await loadSchedules() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            Task { await loadSchedules() }
        }
    }

    // MARK: - Header card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(greeting)
                .font(Typography.screenTitle)
                .foregroundStyle(.white)

            HStack(alignment: .center) {
                Text(dateLabel)
                    .font(Typography.body)
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                let ns = networkStatus
                Button {
                    showAlerts = true
                } label: {
                    HStack(spacing: Spacing.xs + 1) {
                        Image(systemName: ns.icon)
                        Text(ns.label)
                            .font(Typography.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs + 1)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ns.label))
                .accessibilityHint(Text("Voir tous les avis"))
            }

            if let next = nextFavoriteDeparture {
                nextFavoriteBanner(stop: next.stop, entry: next.entry)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motionSafe(.snappy, value: nextFavoriteDeparture?.entry.tripId)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandGradientHeader()
    }

    // MARK: - Next favorite departure (header shortcut)

    /// Soonest upcoming (live-adjusted, not canceled) departure across all
    /// favorite stops, within the next hour.
    private var nextFavoriteDeparture: (stop: Stop, entry: ScheduleEntry)? {
        appVM.favoriteStops
            .compactMap { stop -> (stop: Stop, entry: ScheduleEntry)? in
                let live = appVM.withRealtime(schedulesByStop[stop.id] ?? [], at: stop)
                guard let entry = live
                    .filter({ !$0.hasDepartedToday && !$0.isCanceled && $0.minutesUntilDeparture <= 60 })
                    .min(by: { $0.minutesUntilDeparture < $1.minutesUntilDeparture })
                else { return nil }
                return (stop: stop, entry: entry)
            }
            .min { $0.entry.minutesUntilDeparture < $1.entry.minutesUntilDeparture }
    }

    private func nextFavoriteBanner(stop: Stop, entry: ScheduleEntry) -> some View {
        NavigationLink(value: AppDestination.stop(stop)) {
            HStack(spacing: Spacing.md) {
                RoutePill(shortName: entry.routeShortName, color: entry.routeColor)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(stop.name)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                    if let towards = A11y.towards(entry.headsign) {
                        Text(towards)
                            .font(Typography.caption)
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.sm)
                if entry.delaySeconds != nil {
                    LiveIndicator(color: .white)
                }
                Text(entry.minutesUntilDeparture == 0
                     ? String(localized: "countdown.imminent")
                     : "\(entry.minutesUntilDeparture) min")
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right").accessibilityHidden(true)
                    .font(.caption.weight(.semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(Spacing.md)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.join([
            String(localized: "a11y.next"),
            A11y.route(entry.routeShortName),
            A11y.towards(entry.headsign),
            String(format: String(localized: "a11y.stop"), stop.name),
            A11y.countdown(entry.minutesUntilDeparture),
            A11y.liveStatus(of: entry)
        ]))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Unified stops section

    @ViewBuilder
    private var stopsSection: some View {
        if homeStops.isEmpty {
            SectionHeader(title: "Mes arrêts", icon: "mappin.circle.fill", color: Theme.brandStart)
            emptyStopsCard
        } else {
            SectionHeader(title: "Mes arrêts", icon: "mappin.circle.fill", color: Theme.brandStart)
            VStack(spacing: Spacing.xl) {
                ForEach(homeStops) { stop in
                    StopDeparturesBlock(
                        stop: stop,
                        schedule: appVM.withRealtime(schedulesByStop[stop.id] ?? [], at: stop),
                        isLoading: isLoadingSchedules && schedulesByStop[stop.id] == nil,
                        isFavorite: true,
                        userLocation: appVM.userLocation,
                        emptyNotice: appVM.serviceNotStartedMessage(for: stop.providerId)
                    ) {
                        path.append(AppDestination.stop(stop))
                    }
                    .contextMenu {
                        Button {
                            withMotionAnimation { appVM.toggleFavorite(stop) }
                        } label: {
                            Label("Retirer des favoris", systemImage: "star.slash")
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .motionSafe(.snappy(duration: 0.28), value: homeStops.map(\.favoriteKey))
        }
    }

    private var emptyStopsCard: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: "star.circle")
                .scaledIcon(36)
                .accessibilityHidden(true)   // decorative
                .foregroundStyle(Theme.favorite)
            VStack(alignment: .leading, spacing: 3) {
                Text("Aucun favori")
                    .font(.body.weight(.semibold))
                Text("Touchez l'étoile d'un arrêt, sur la carte, pour le retrouver ici.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Spacing.xl)
        .card(cornerRadius: Radius.lg)
    }

    // MARK: - Alerts section

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Avis actifs", icon: "exclamationmark.triangle.fill", color: Theme.statusWarning)

            VStack(spacing: 6) {
                ForEach(appVM.serviceAlerts.prefix(3)) { alert in
                    AlertTeaserRow(alert: alert)
                }
                if appVM.serviceAlerts.count > 3 {
                    Text(Plural.moreAlerts(appVM.serviceAlerts.count - 3))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Schedule loading

    private func loadSchedules() async {
        let stops = homeStops
        guard !stops.isEmpty else { return }
        isLoadingSchedules = true
        schedulesByStop = await appVM.loadSchedules(for: stops)
        isLoadingSchedules = false
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsView: some View {
        let routes = searchRouteResults
        let stops  = searchStopResults
        if routes.isEmpty && stops.isEmpty {
            ContentUnavailableView(
                "Aucun résultat",
                systemImage: "magnifyingglass",
                description: Text("Essayez un autre nom ou numéro.")
            )
        } else {
            List {
                if !routes.isEmpty {
                    Section("Lignes") {
                        ForEach(routes) { route in
                            NavigationLink(value: AppDestination.route(route)) {
                                RouteRow(route: route)
                            }
                        }
                    }
                }
                if !stops.isEmpty {
                    Section("Arrêts") {
                        ForEach(stops) { stop in
                            NavigationLink(value: AppDestination.stop(stop)) {
                                StopResultRow(stop: stop)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

// MARK: - Stop result row

private struct StopResultRow: View {
    @EnvironmentObject var appVM: AppViewModel
    let stop: Stop

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stop.symbolName).accessibilityHidden(true)
                .frame(width: 20)
                .foregroundStyle(stop.isStation ? Theme.brandStart : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(stop.isStation ? "Station de métro" : "Arrêt d'autobus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let loc = appVM.userLocation {
                        if stop.distance(from: loc) < 5_000 {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                            Text(stop.formattedDistance(from: loc))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            if appVM.isFavorite(stop) {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.favorite)
            }
            Image(systemName: "chevron.right").accessibilityHidden(true).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Alert Teaser Row

private struct AlertTeaserRow: View {
    let alert: ServiceAlert

    var body: some View {
        let color = alert.severityColor
        HStack(spacing: Spacing.m) {
            Image(systemName: alert.effectIcon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 20)

            Text(alert.typeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, Spacing.s).padding(.vertical, Spacing.xxs)
                .background(color.opacity(0.12), in: Capsule())

            Text(alert.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.m)
        .background(color.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }
}
