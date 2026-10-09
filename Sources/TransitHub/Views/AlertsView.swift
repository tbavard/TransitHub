import SwiftUI

struct AlertsView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @State private var selectedRouteFilter: String? = nil

    private var hasData: Bool {
        !appVM.serviceAlerts.isEmpty || !appVM.routeDelays.isEmpty
    }

    /// True when at least one configured provider can deliver realtime data
    /// (either doesn't need a key, or has one stored).
    private var hasRealtimeAccess: Bool {
        providersStore.providers.contains {
            $0.supportsRealtime && GTFSRealtimeService.forProvider($0).hasAPIKey
        }
    }

    /// True when at least one configured provider supports realtime but is missing its key.
    private var needsRealtimeKey: Bool {
        providersStore.providers.contains {
            $0.needsRealtimeKey && GTFSRealtimeService.forProvider($0).apiKey.isEmpty
        }
    }

    var filteredAlerts: [ServiceAlert] {
        guard let id = selectedRouteFilter else { return appVM.serviceAlerts }
        return appVM.serviceAlerts.filter { $0.affectedRouteIds.contains(id) }
    }

    var filteredDelays: [RouteDelay] {
        guard let id = selectedRouteFilter else { return appVM.routeDelays }
        return appVM.routeDelays.filter { $0.routeId == id }
    }

    // Union of routes touched by either data source, for the filter chips
    var affectedRoutes: [Route] {
        var ids = Set(appVM.routeDelays.map { $0.routeId })
        for a in appVM.serviceAlerts { ids.formUnion(a.affectedRouteIds) }
        return appVM.routes.filter { ids.contains($0.gtfsId) }
            .sorted { $0.shortName < $1.shortName }
    }

    var body: some View {
        NavigationStack {
            Group {
                if providersStore.providers.isEmpty {
                    NoProvidersView()
                } else if !hasRealtimeAccess && needsRealtimeKey {
                    missingKeyView
                } else if appVM.isRefreshingRealtime && !hasData {
                    ProgressView("Chargement…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasData {
                    ContentUnavailableView(
                        "Aucun avis actif",
                        systemImage: "checkmark.circle",
                        description: Text("Le réseau fonctionne normalement.")
                    )
                } else {
                    avisContent
                }
            }
            .navigationTitle("Avis & Retards")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if appVM.isRefreshingRealtime {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button {
                            Task { await appVM.refreshRealtime() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(!hasRealtimeAccess)
                    }
                }
            }
            .task {
                if !hasData { await appVM.refreshRealtime() }
            }
            .safeAreaInset(edge: .bottom) {
                if let err = appVM.realtimeError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(err.localizedDescription)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - Network status banner

    private var networkStatusBanner: some View {
        let criticalCount = appVM.serviceAlerts.filter { $0.severityLevel >= 3 }.count
        let alertCount = appVM.serviceAlerts.count
        let delayCount = appVM.routeDelays.count

        let (icon, label, color): (String, String, Color) = {
            if criticalCount > 0 {
                return ("xmark.circle.fill",
                        String(format: String(localized: "alerts.critical_count"), criticalCount),
                        .red)
            } else if alertCount > 0 || delayCount > 0 {
                let parts = [
                    alertCount > 0 ? String(format: String(localized: "alerts.alert_count"), alertCount) : nil,
                    delayCount > 0 ? String(format: String(localized: "alerts.delay_count"), delayCount) : nil
                ].compactMap { $0 }.joined(separator: " · ")
                return ("exclamationmark.triangle.fill", parts, .orange)
            } else {
                return ("checkmark.circle.fill", String(localized: "network.normal"), .green)
            }
        }()

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.1))
    }

    // MARK: - Combined content

    private var avisContent: some View {
        VStack(spacing: 0) {
            networkStatusBanner
            Divider()
            if !affectedRoutes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "Tous", isSelected: selectedRouteFilter == nil) {
                            selectedRouteFilter = nil
                        }
                        ForEach(affectedRoutes) { route in
                            FilterChip(
                                label: route.shortName,
                                color: route.routeColor,
                                isSelected: selectedRouteFilter == route.gtfsId
                            ) {
                                selectedRouteFilter = selectedRouteFilter == route.gtfsId ? nil : route.gtfsId
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGroupedBackground))
                Divider()
            }

            List {
                if !filteredAlerts.isEmpty {
                    Section("Avis de service") {
                        ForEach(filteredAlerts) { alert in
                            AlertRow(alert: alert, routes: appVM.routes)
                        }
                    }
                }

                if !filteredDelays.isEmpty {
                    Section("Retards en temps réel") {
                        ForEach(filteredDelays) { delay in
                            DelayRow(delay: delay,
                                     route: appVM.routes.first { $0.gtfsId == delay.routeId })
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await appVM.refreshRealtime() }
        }
    }

    // MARK: - Missing API key prompt

    private var missingKeyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.slash.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Clé API requise")
                .font(.headline)
            Text("Accédez aux avis et retards en temps réel en enregistrant votre clé dans les réglages.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            NavigationLink(destination: SettingsView()) {
                Label("Réglages", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Alert Row (service alerts from État du Service)

struct AlertRow: View {
    let alert: ServiceAlert
    let routes: [Route]
    @State private var isExpanded = false

    private func route(for id: String) -> Route? {
        routes.first { $0.gtfsId == id }
    }

    var body: some View {
        let color = alert.severityColor
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: alert.effectIcon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            Text(alert.typeLabel)
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(color.opacity(0.15), in: Capsule())
                                .foregroundStyle(color)

                            ForEach(alert.affectedRouteIds.prefix(4), id: \.self) { rid in
                                if let r = route(for: rid) {
                                    Text(r.shortName)
                                        .font(.caption.bold())
                                        .foregroundStyle(r.routeTextColor)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(r.routeColor,
                                                    in: RoundedRectangle(cornerRadius: 4))
                                } else {
                                    Text(rid)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Color(.systemFill),
                                                    in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            if alert.affectedRouteIds.count > 4 {
                                Text("+\(alert.affectedRouteIds.count - 4)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()
                    if !alert.body.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded && !alert.body.isEmpty {
                Text(alert.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
                    .padding(.bottom, 10)
            }
        }
    }
}

// MARK: - Delay Row (computed from GTFS-RT tripUpdates)

struct DelayRow: View {
    let delay: RouteDelay
    let route: Route?

    var body: some View {
        let color = delay.severityColor
        HStack(spacing: 12) {
            Image(systemName: delay.effectIcon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let r = route {
                        Text(r.shortName)
                            .font(.caption.bold())
                            .foregroundStyle(r.routeTextColor)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(r.routeColor, in: RoundedRectangle(cornerRadius: 4))
                        Text(r.longName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                    } else {
                        Text("Ligne \(delay.routeId)")
                            .font(.body.weight(.medium))
                    }
                }

                HStack(spacing: 8) {
                    Text(delay.delayLabel)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color.opacity(0.15), in: Capsule())
                        .foregroundStyle(color)
                    Text("\(delay.delayedTripCount)/\(delay.totalTripCount) trajets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    var color: Color = .blue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : Color(.systemFill), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
