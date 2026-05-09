import SwiftUI
import CoreLocation

struct FavoritesView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @State private var selectedStop: Stop?
    @State private var schedulesByStop: [String: [ScheduleEntry]] = [:]
    @State private var isLoadingSchedules = false
    @State private var searchText = ""
    @State private var showAlerts = false

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

    // Nearest stops excluding already-favorited ones
    private var nearestStops: [Stop] {
        guard let loc = appVM.userLocation else { return [] }
        let favKeys = Set(appVM.favoriteStops.map(\.favoriteKey))
        return appVM.nearestStops(to: loc, count: 8)
            .filter { !favKeys.contains($0.favoriteKey) }
            .prefix(4)
            .map { $0 }
    }

    /// Favorites first (sorted by distance if known), then nearest non-favorites.
    private var homeStops: [Stop] {
        let favs: [Stop]
        if let loc = appVM.userLocation {
            favs = appVM.favoriteStops.sorted {
                $0.distance(from: loc) < $1.distance(from: loc)
            }
        } else {
            favs = appVM.favoriteStops
        }
        return favs + nearestStops
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
                    String(format: String(localized: "network.disruptions"), critical), .red)
        }
        if total > 0 {
            return ("exclamationmark.triangle.fill",
                    String(format: String(localized: "network.alerts"), total), .orange)
        }
        return ("checkmark.circle.fill", String(localized: "network.normal"), .green)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if providersStore.providers.isEmpty {
                    NoProvidersView()
                } else if !searchText.isEmpty {
                    searchResultsView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            headerCard
                            if !appVM.serviceAlerts.isEmpty { alertsSection }
                            stopsSection
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .background(Color(.systemGroupedBackground))
                    .refreshable {
                        schedulesByStop = [:]
                        await loadSchedules()
                    }
                }
            }
            .navigationTitle("Tableau de bord")
            .searchable(text: $searchText, prompt: "Ligne, arrêt, numéro…")
            .navigationDestination(for: Route.self) { route in
                RouteDetailView(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(item: $selectedStop) { stop in
                NavigationStack { StopDetailView(stop: stop) }
                    .presentationDetents([.medium, .large])
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
        VStack(alignment: .leading, spacing: 8) {
            Text(greeting)
                .font(.largeTitle.bold())

            HStack(alignment: .center) {
                Text(dateLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                let ns = networkStatus
                Button {
                    showAlerts = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: ns.icon)
                        Text(ns.label)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ns.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ns.color.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ns.label))
                .accessibilityHint(Text("Voir tous les avis"))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Unified stops section

    @ViewBuilder
    private var stopsSection: some View {
        if homeStops.isEmpty {
            SectionHeader(title: "Mes arrêts", icon: "mappin.and.ellipse", color: .blue)
            emptyStopsCard
        } else {
            SectionHeader(title: "Mes arrêts", icon: "mappin.and.ellipse", color: .blue)
            VStack(spacing: 12) {
                ForEach(homeStops) { stop in
                    Button { selectedStop = stop } label: {
                        TransitStopCard(
                            stop: stop,
                            schedule: schedulesByStop[stop.id] ?? [],
                            userLocation: appVM.userLocation,
                            isFavorite: appVM.isFavorite(stop),
                            isLoading: isLoadingSchedules && schedulesByStop[stop.id] == nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            withAnimation { appVM.toggleFavorite(stop) }
                        } label: {
                            if appVM.isFavorite(stop) {
                                Label("Retirer des favoris", systemImage: "star.slash")
                            } else {
                                Label("Ajouter aux favoris", systemImage: "star")
                            }
                        }
                    } preview: {
                        TransitStopCard(
                            stop: stop,
                            schedule: schedulesByStop[stop.id] ?? [],
                            userLocation: appVM.userLocation,
                            isFavorite: appVM.isFavorite(stop),
                            isLoading: false
                        )
                        .frame(width: 340)
                    }
                }
            }
        }
    }

    private var emptyStopsCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "star.circle")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Aucun arrêt")
                    .font(.body.weight(.semibold))
                Text("Ajoutez un favori ou activez la localisation pour voir les arrêts à proximité.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Alerts section

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Avis actifs", icon: "exclamationmark.triangle.fill", color: .orange)

            VStack(spacing: 6) {
                ForEach(appVM.serviceAlerts.prefix(3)) { alert in
                    AlertTeaserRow(alert: alert)
                }
                if appVM.serviceAlerts.count > 3 {
                    Text("+ \(appVM.serviceAlerts.count - 3) autre(s) avis")
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
                            NavigationLink(value: route) {
                                RouteRow(route: route)
                            }
                        }
                    }
                }
                if !stops.isEmpty {
                    Section("Arrêts") {
                        ForEach(stops) { stop in
                            Button { selectedStop = stop } label: {
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
            Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                .frame(width: 20)
                .foregroundStyle(stop.isStation ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(stop.isStation ? "Station de métro" : "Arrêt d'autobus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let loc = appVM.userLocation {
                        let dist = stop.distance(from: loc)
                        if dist < 5_000 {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                            Text(dist < 1_000
                                 ? String(format: "%.0f m", dist)
                                 : String(format: "%.1f km", dist / 1_000))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            if appVM.isFavorite(stop) {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
        }
    }
}

// MARK: - Transit App-style stop card (single card shared by favorites + nearby)

struct TransitStopCard: View {
    let stop: Stop
    let schedule: [ScheduleEntry]
    let userLocation: CLLocation?
    var isFavorite: Bool = false
    var isLoading: Bool = false
    var maxRoutes: Int = 5

    private var groups: [RouteDeparturesGroup] { schedule.groupedByRouteAndHeadsign(limit: 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if isLoading {
                Divider().padding(.leading, 14)
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        TransitRouteRowPlaceholder()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if i < 2 { Divider().padding(.leading, 14 + 44 + 12) }
                    }
                }
            } else if groups.isEmpty {
                Divider().padding(.leading, 14)
                Text(schedule.isEmpty ? "Aucun service actif" : "Aucun départ prochain")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else {
                Divider().padding(.leading, 14)
                VStack(spacing: 0) {
                    let shown = Array(groups.prefix(maxRoutes))
                    ForEach(shown.indices, id: \.self) { i in
                        TransitRouteRow(group: shown[i])
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if i < shown.count - 1 {
                            Divider().padding(.leading, 14 + 44 + 12)
                        }
                    }
                    if groups.count > maxRoutes {
                        HStack {
                            Text("+ \(groups.count - maxRoutes) autre(s) ligne(s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isFavorite ? 0.08 : 0.04),
                radius: isFavorite ? 5 : 3, x: 0, y: 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    Text(stop.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    ProviderBadge(providerId: stop.providerId)
                    if let loc = userLocation {
                        Text(stop.formattedDistance(from: loc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Transit App-style route row

struct TransitRouteRow: View {
    let group: RouteDeparturesGroup

    var body: some View {
        HStack(spacing: 12) {
            RoutePill(shortName: group.routeShortName, color: group.routeColor)
                .frame(width: 44)

            Text(group.headsign.isEmpty ? "—" : group.headsign)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                let mins = Array(group.minutes.prefix(3))
                ForEach(mins.indices, id: \.self) { i in
                    CountdownLabel(minutes: mins[i], emphasised: i == 0)
                }
            }
        }
    }
}

private struct TransitRouteRowPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemFill))
                .frame(width: 44, height: 28)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemFill))
                .frame(height: 12)
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemFill))
                .frame(width: 36, height: 14)
        }
        .redacted(reason: .placeholder)
    }
}

// MARK: - Route pill

struct RoutePill: View {
    let shortName: String
    let color: String

    var body: some View {
        Text(shortName)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: 40)
            .background(Color(hex: color) ?? .blue,
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Countdown label

struct CountdownLabel: View {
    let minutes: Int
    var emphasised: Bool = false

    private var urgencyColor: Color {
        if minutes <= 1 { return .green }
        if minutes <= 5 { return .orange }
        return .primary
    }

    var body: some View {
        if minutes < 60 {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(minutes == 0 ? "•" : "\(minutes)")
                    .font(.system(size: emphasised ? 20 : 15,
                                  weight: emphasised ? .bold : .semibold,
                                  design: .rounded))
                    .monospacedDigit()
                if minutes > 0 {
                    Text("min")
                        .font(.system(size: emphasised ? 11 : 10, weight: .medium))
                        .opacity(0.7)
                } else {
                    Text("now")
                        .font(.system(size: emphasised ? 11 : 10, weight: .semibold))
                }
            }
            .foregroundStyle(emphasised ? urgencyColor : .secondary)
        } else {
            let h = minutes / 60
            let m = minutes % 60
            Text(m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))")
                .font(.system(size: emphasised ? 16 : 13,
                              weight: emphasised ? .bold : .semibold,
                              design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasised ? urgencyColor : .secondary)
        }
    }
}

// MARK: - Alert Teaser Row

private struct AlertTeaserRow: View {
    let alert: ServiceAlert

    var body: some View {
        let color = alert.severityColor
        HStack(spacing: 10) {
            Image(systemName: alert.effectIcon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 20)

            Text(alert.typeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.12), in: Capsule())

            Text(alert.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }
}
