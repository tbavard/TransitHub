import SwiftUI
import MapKit

// MARK: - Map home
//
// The app's home screen: a full-screen map with a draggable bottom panel.
// The panel lists what is passing near the user as route-coloured cards
// (swipe a card for the following departures); tapping a stop pin shows that
// stop instead. "Où allez-vous ?" opens the trip planner over the map.

struct TransitMapView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @ObservedObject var locationService: LocationService

    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 45.5088, longitude: -73.5878),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    ))
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 45.5088, longitude: -73.5878),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    @State private var previewStop: Stop?
    @State private var previewSchedule: [ScheduleEntry] = []
    @State private var isLoadingPreview = false
    @State private var isFollowingUser = false
    @State private var showVehicles = true

    // Panel, navigation, presentations
    @State private var detent: PanelDetent = .half
    @State private var path = NavigationPath()
    @State private var showPlan = false
    @State private var showSettings = false

    // Nearby stops listed in the panel
    @StateObject private var loader = StopSchedulesLoader()
    @State private var nearbyStops: [Stop] = []

    /// Cached routeId → color map so vehicle annotations don't do an O(N) scan
    /// of `appVM.routes` on every SwiftUI redraw. Rebuilt when routes change.
    @State private var routeColorIndex: [String: Color] = [:]

    /// Cap on annotations rendered at once. Empirically the map starts
    /// dropping frames past ~200 SwiftUI annotations; 150 gives headroom
    /// while still covering a downtown region comfortably.
    private static let maxVehicleAnnotations = 150

    /// Hide vehicles when zoomed out — same threshold idea as stops but a
    /// bit more generous since vehicles are sparser.
    private static let vehicleZoomThreshold: Double = 0.12

    /// How many nearby stops the panel lists.
    private static let nearbyStopCount = 5

    var visibleStops: [Stop] {
        guard visibleRegion.span.latitudeDelta < 0.08 else { return [] }
        return appVM.stopsInRegion(
            centerLat: visibleRegion.center.latitude,
            centerLon: visibleRegion.center.longitude,
            latDelta:  visibleRegion.span.latitudeDelta,
            lonDelta:  visibleRegion.span.longitudeDelta,
            max: 250
        )
    }

    /// Routes served by the currently previewed stop, derived from its schedule.
    private var previewRouteIds: Set<String> {
        Set(previewSchedule.map { $0.routeId })
    }

    var visibleVehicles: [VehiclePosition] {
        guard showVehicles,
              visibleRegion.span.latitudeDelta < Self.vehicleZoomThreshold
        else { return [] }
        // Hoist the region bounds out of the closure so we don't re-read the
        // MKCoordinateRegion fields on every vehicle comparison.
        let centerLat = visibleRegion.center.latitude
        let centerLon = visibleRegion.center.longitude
        let latBuf = visibleRegion.span.latitudeDelta * 1.5
        let lonBuf = visibleRegion.span.longitudeDelta * 1.5
        var out: [VehiclePosition] = []
        out.reserveCapacity(min(appVM.vehiclePositions.count, Self.maxVehicleAnnotations))
        for v in appVM.vehiclePositions {
            if abs(v.lat - centerLat) < latBuf && abs(v.lon - centerLon) < lonBuf {
                out.append(v)
                if out.count >= Self.maxVehicleAnnotations { break }
            }
        }
        return out
    }

    private func rebuildRouteColorIndex() {
        var idx: [String: Color] = [:]
        idx.reserveCapacity(appVM.routes.count)
        for r in appVM.routes { idx[r.gtfsId] = r.routeColor }
        routeColorIndex = idx
    }

    private var nearbyKey: String {
        nearbyStops.map(\.favoriteKey).joined(separator: ",")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                mapLayer
                overlayButtons
                BottomPanel(detent: $detent) { panelContent }
            }
            .toolbar(.hidden, for: .navigationBar)
            .appDestinations()
        }
        .fullScreenCover(isPresented: $showPlan) {
            PlanView(onClose: { showPlan = false })
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { showSettings = false }
                        }
                    }
            }
        }
        .task(id: nearbyKey) {
            await loader.load(stops: nearbyStops, using: appVM)
        }
        .onChange(of: previewStop?.favoriteKey) { _, key in
            if key != nil && detent == .collapsed { detent = .half }
            Task { await loadPreviewSchedule() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            Task {
                await loadPreviewSchedule()
                await loader.load(stops: nearbyStops, using: appVM)
            }
        }
        .onChange(of: locationService.location) { _, loc in
            updateNearbyStops()
            guard let loc else { return }
            if isFollowingUser || initialCentering != .user {
                if initialCentering != .user { initialCentering = .user }
                centerToLocation(loc)
            }
        }
        .onAppear {
            centerInitiallyIfNeeded()
            updateNearbyStops()
            if routeColorIndex.isEmpty { rebuildRouteColorIndex() }
            if appVM.pendingPlanDestination != nil { showPlan = true }
        }
        .onChange(of: appVM.stops.count) { _, _ in
            centerInitiallyIfNeeded()
            updateNearbyStops()
        }
        .onChange(of: appVM.routes) { _, _ in
            rebuildRouteColorIndex()
        }
        // "Y aller" from a stop screen: open the planner on that destination.
        .onChange(of: appVM.pendingPlanDestination) { _, stop in
            if stop != nil { showPlan = true }
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Map(position: $position, selection: .constant(nil)) {
            UserAnnotation()

            ForEach(visibleStops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                    StopPin(stop: stop, isSelected: previewStop?.favoriteKey == stop.favoriteKey) {
                        withMotionAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            if previewStop?.favoriteKey == stop.favoriteKey {
                                closePreview()
                            } else {
                                previewStop = stop
                                previewSchedule = []
                            }
                        }
                    }
                }
            }

            ForEach(visibleVehicles) { vehicle in
                Annotation("", coordinate: vehicle.coordinate, anchor: .center) {
                    let isHighlighted = previewRouteIds.isEmpty
                        || previewRouteIds.contains(vehicle.routeId)
                    VehicleArrow(
                        bearing: vehicle.bearing,
                        color: routeColorIndex[vehicle.routeId] ?? Theme.soon
                    )
                    .opacity(isHighlighted ? 1.0 : 0.3)
                }
            }
        }
        .mapControls { }
        .onMapCameraChange { ctx in
            visibleRegion = ctx.region
            if isFollowingUser, let loc = locationService.location {
                let dist = CLLocation(latitude: ctx.region.center.latitude,
                                     longitude: ctx.region.center.longitude)
                    .distance(from: loc)
                // The camera is parked a bit south of the user (the panel covers
                // the lower half), so allow for that offset.
                if dist > 600 { isFollowingUser = false }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Floating buttons

    private var overlayButtons: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Button { showSettings = true } label: {
                    Image(systemName: "person.crop.circle")
                }
                .buttonStyle(.floatingCircle)
                .accessibilityLabel(Text("Profil et réglages"))

                if let status = networkIssue { statusPill(status) }

                if visibleRegion.span.latitudeDelta > 0.08 {
                    Text("Zoomez pour\nvoir les arrêts")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .padding(Spacing.sm)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md))
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: Spacing.sm) {
                if !appVM.vehiclePositions.isEmpty {
                    Button { showVehicles.toggle() } label: {
                        Image(systemName: showVehicles ? "bus.fill" : "bus")
                            .foregroundStyle(showVehicles ? Theme.soonText : Color.secondary)
                    }
                    .buttonStyle(.floatingCircle)
                    .accessibilityLabel(Text(showVehicles ? "Masquer les véhicules" : "Afficher les véhicules"))
                    .accessibilityAddTraits(showVehicles ? .isSelected : [])
                }

                Button { centerOnUser() } label: {
                    Image(systemName: isFollowingUser ? "location.fill" : "location")
                        .foregroundStyle(isFollowingUser ? Theme.brandStart : Color.primary)
                }
                .buttonStyle(.floatingCircle)
                .accessibilityLabel(Text("Centrer sur ma position"))
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private typealias NetworkIssue = (icon: String, label: String, color: Color)

    /// Only shown when something is wrong; opens the alerts tab.
    private var networkIssue: NetworkIssue? {
        let critical = appVM.serviceAlerts.filter { $0.severityLevel >= 3 }.count
        let total = appVM.serviceAlerts.count + appVM.routeDelays.count
        if critical > 0 {
            return ("xmark.circle.fill",
                    String(format: String(localized: "network.disruptions"), critical),
                    Theme.statusCritical)
        }
        if total > 0 {
            return ("exclamationmark.triangle.fill",
                    String(format: String(localized: "network.alerts"), total),
                    Theme.statusWarning)
        }
        return nil
    }

    private func statusPill(_ status: NetworkIssue) -> some View {
        Button { appVM.selectedTab = .alerts } label: {
            HStack(spacing: Spacing.xs + 1) {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                Text(status.label)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.sm)
            .background(Color(.systemBackground), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Voir tous les avis"))
    }

    // MARK: - Panel

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            searchPill
            if detent != .collapsed {
                if let stop = previewStop {
                    stopSection(stop)
                } else {
                    nearbySection
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.xxxl)
    }

    private var searchPill: some View {
        Button { showPlan = true } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Où allez-vous ?")
                    .font(Typography.cardTitle)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .background(Theme.brandGradient, in: Capsule())
            .shadow(color: Theme.brandStart.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: Nearby

    @ViewBuilder
    private var nearbySection: some View {
        if locationService.location == nil {
            locationHint
        } else if nearbyStops.isEmpty {
            Text("Aucun arrêt à proximité")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.lg)
        } else {
            ForEach(nearbyStops) { stop in
                nearbyStopBlock(stop)
            }
        }
    }

    private var locationHint: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Activez la localisation pour voir ce qui passe près de vous.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
            if locationService.needsSettings {
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if !locationService.isAuthorized {
                Button("Autoriser la localisation") {
                    locationService.requestAuthorization()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, Spacing.md)
    }

    private func nearbyStopBlock(_ stop: Stop) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button { path.append(AppDestination.stop(stop)) } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: stop.symbolName)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(stop.name)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let loc = locationService.location {
                        Text(stop.formattedDistance(from: loc))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            departureCards(for: loader.schedule(for: stop, using: appVM),
                           stop: stop,
                           isLoading: loader.isLoading(stop))
        }
    }

    // MARK: Previewed stop

    private func stopSection(_ stop: Stop) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: stop.symbolName)
                    .font(.title3)
                    .foregroundStyle(Theme.brandStart)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(stop.name)
                        .font(Typography.sectionTitle)
                        .lineLimit(2)
                    HStack(spacing: Spacing.s) {
                        ProviderBadge(providerId: stop.providerId)
                        if let loc = locationService.location {
                            Text(stop.formattedDistance(from: loc))
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: Spacing.xs)
                Button {
                    withMotionAnimation(.spring(duration: 0.25)) { appVM.toggleFavorite(stop) }
                } label: {
                    Image(systemName: appVM.isFavorite(stop) ? "star.fill" : "star")
                        .foregroundStyle(appVM.isFavorite(stop) ? Theme.favorite : Color.secondary)
                }
                .buttonStyle(.floatingCircle)
                .accessibilityLabel(Text(appVM.isFavorite(stop) ? "Retirer des favoris" : "Ajouter aux favoris"))
                Button {
                    withMotionAnimation(.spring(response: 0.3)) { closePreview() }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.floatingCircle)
                .accessibilityLabel(Text("Fermer"))
            }

            departureCards(for: appVM.withRealtime(previewSchedule, at: stop),
                           stop: stop,
                           isLoading: isLoadingPreview)

            HStack(spacing: Spacing.sm) {
                actionCapsule("Voir tous les horaires", icon: "clock", filled: true) {
                    path.append(AppDestination.stop(stop))
                }
                actionCapsule("Y aller", icon: "arrow.triangle.turn.up.right.diamond", filled: false) {
                    appVM.pendingPlanDestination = stop
                    showPlan = true
                }
            }
        }
    }

    private func actionCapsule(_ title: LocalizedStringKey, icon: String, filled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(title).font(Typography.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.m)
            .foregroundStyle(filled ? Color.white : Theme.brandStart)
            .background(filled ? AnyShapeStyle(Theme.brandGradient)
                               : AnyShapeStyle(Theme.brandStart.opacity(0.12)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Shared: a stop's departures as cards

    @ViewBuilder
    private func departureCards(for schedule: [ScheduleEntry], stop: Stop, isLoading: Bool) -> some View {
        let groups = schedule.groupedByRouteAndHeadsign(limit: 5)
        if isLoading && groups.isEmpty {
            RouteDepartureCardPlaceholder()
        } else if groups.isEmpty {
            Text(appVM.serviceNotStartedMessage(for: stop.providerId) ?? String(localized: "Aucun départ prochain"))
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.sm)
        } else {
            ForEach(Array(groups.prefix(4))) { group in
                RouteDepartureCard(group: group)
                    .onTapGesture { path.append(AppDestination.stop(stop)) }
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    // MARK: - Initial centering
    //
    // The camera used to start on a hard-coded Montreal region whatever the
    // user's network. Now: the user's position when known; otherwise the
    // middle of the loaded network; the first location fix then takes over.

    private enum InitialCentering { case none, network, user }
    @State private var initialCentering: InitialCentering = .none

    private func centerInitiallyIfNeeded() {
        if let loc = locationService.location {
            guard initialCentering != .user else { return }
            initialCentering = .user
            centerToLocation(loc)
        } else if initialCentering == .none, let center = networkCenter() {
            initialCentering = .network
            position = .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
    }

    /// Median stop coordinate — robust to a few outlying stops (airport
    /// shuttles, regional lines) that would drag a plain average away.
    private func networkCenter() -> CLLocationCoordinate2D? {
        let stops = appVM.stops
        guard !stops.isEmpty else { return nil }
        let lats = stops.map(\.lat).sorted()
        let lons = stops.map(\.lon).sorted()
        return CLLocationCoordinate2D(latitude: lats[lats.count / 2], longitude: lons[lons.count / 2])
    }

    // MARK: - Actions

    private func centerOnUser() {
        guard let loc = locationService.location else {
            locationService.requestAuthorization(); return
        }
        isFollowingUser = true
        centerToLocation(loc)
    }

    /// Centers on the user, parked a little north of the middle of the screen:
    /// the panel covers the lower half of the map.
    private func centerToLocation(_ loc: CLLocation) {
        let span = 0.015
        let center = CLLocationCoordinate2D(
            latitude: loc.coordinate.latitude - span * 0.18,
            longitude: loc.coordinate.longitude)
        withMotionAnimation { position = .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        ))}
    }

    private func closePreview() {
        previewStop = nil
        previewSchedule = []
    }

    private func updateNearbyStops() {
        guard let loc = locationService.location else {
            nearbyStops = []
            return
        }
        nearbyStops = appVM.nearestStops(to: loc, count: Self.nearbyStopCount)
    }

    private func loadPreviewSchedule() async {
        guard let stop = previewStop else {
            previewSchedule = []
            return
        }
        isLoadingPreview = previewSchedule.isEmpty
        let fetched = (try? await appVM.fetchSchedule(for: stop)) ?? []
        if previewStop?.favoriteKey == stop.favoriteKey {
            previewSchedule = fetched
        }
        isLoadingPreview = false
    }
}

// MARK: - Stop pin

struct StopPin: View {
    let stop: Stop
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if stop.isStation {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Theme.soon : Theme.brandStart)
                        .frame(width: 22, height: 22)
                    Image(systemName: "m.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else {
                Circle()
                    .fill(isSelected ? Theme.soon : Theme.brandStart.opacity(0.8))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain)
        .minTouchTarget()
        .scaleEffect(isSelected ? 1.5 : 1.0)
        .motionSafe(.spring(duration: 0.2), value: isSelected)
        .accessibilityLabel(String(format: String(localized: "a11y.stop"), stop.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Vehicle arrow

struct VehicleArrow: View {
    let bearing: Float
    let color: Color

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(Double(bearing)))
            .padding(4)
            .background(.white.opacity(0.95), in: Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .accessibilityHidden(true)   // moving vehicles would flood VoiceOver
    }
}
