import SwiftUI
import MapKit

struct TransitMapView: View {
    @EnvironmentObject var appVM: AppViewModel
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
    @State private var showFullSheet = false
    @State private var isFollowingUser = false
    @State private var showVehicles = true

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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $position, selection: .constant(nil)) {
                UserAnnotation()

                ForEach(visibleStops) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                        StopPin(stop: stop, isSelected: previewStop?.favoriteKey == stop.favoriteKey) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                if previewStop?.favoriteKey == stop.favoriteKey {
                                    previewStop = nil
                                    previewSchedule = []
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
                            color: routeColorIndex[vehicle.routeId] ?? .orange
                        )
                        .opacity(isHighlighted ? 1.0 : 0.3)
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange { ctx in
                visibleRegion = ctx.region
                if isFollowingUser, let loc = locationService.location {
                    let dist = CLLocation(latitude: ctx.region.center.latitude,
                                         longitude: ctx.region.center.longitude)
                        .distance(from: loc)
                    if dist > 200 { isFollowingUser = false }
                }
            }
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 12) {
                if visibleRegion.span.latitudeDelta > 0.08 {
                    Text("Zoomez pour\nvoir les arrêts")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                if !appVM.vehiclePositions.isEmpty {
                    Button {
                        showVehicles.toggle()
                    } label: {
                        Image(systemName: showVehicles ? "bus.fill" : "bus")
                            .font(.title3)
                            .padding(12)
                            .background(.regularMaterial, in: Circle())
                            .foregroundStyle(showVehicles ? .orange : .secondary)
                    }
                }

                Button { centerOnUser() } label: {
                    Image(systemName: isFollowingUser ? "location.fill" : "location")
                        .font(.title3)
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                        .foregroundStyle(isFollowingUser ? .blue : .primary)
                }
            }
            .padding()
            // Push the map controls above the preview card so they don't get
            // covered. Static 210pt covers the typical card height (header +
            // up to 3 route rows + CTA button).
            .padding(.bottom, previewStop != nil ? 210 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8),
                       value: previewStop?.favoriteKey)
        }
        // Overlay the preview card on top of the map instead of using
        // `.safeAreaInset` — the inset reshaped the Map's safe area on every
        // present/dismiss, forcing MapKit to relayout (visible as a flicker
        // and brief full-screen resize). Overlay keeps the map frame stable.
        .overlay(alignment: .bottom) {
            if let stop = previewStop {
                MapStopPreviewCard(
                    stop: stop,
                    schedule: previewSchedule,
                    userLocation: locationService.location,
                    isFavorite: appVM.isFavorite(stop),
                    isLoading: isLoadingPreview
                ) {
                    showFullSheet = true
                } onDismiss: {
                    withAnimation(.spring(response: 0.3)) {
                        previewStop = nil
                        previewSchedule = []
                    }
                } onFavoriteToggle: {
                    withAnimation(.spring(duration: 0.25)) {
                        appVM.toggleFavorite(stop)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: previewStop?.favoriteKey)
        .sheet(isPresented: $showFullSheet) {
            if let stop = previewStop {
                NavigationStack { StopDetailView(stop: stop) }
                    .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: previewStop?.favoriteKey) { _, _ in
            Task { await loadPreviewSchedule() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            Task { await loadPreviewSchedule() }
        }
        .onChange(of: locationService.location) { _, loc in
            guard let loc, isFollowingUser else { return }
            withAnimation { position = .region(MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
            ))}
        }
        .onAppear {
            if let loc = locationService.location { centerToLocation(loc) }
            if routeColorIndex.isEmpty { rebuildRouteColorIndex() }
        }
        .onChange(of: appVM.routes) { _, _ in
            rebuildRouteColorIndex()
        }
    }

    // MARK: - Actions

    private func centerOnUser() {
        guard let loc = locationService.location else {
            locationService.requestAuthorization(); return
        }
        isFollowingUser = true
        centerToLocation(loc)
    }

    private func centerToLocation(_ loc: CLLocation) {
        withAnimation { position = .region(MKCoordinateRegion(
            center: loc.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        ))}
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
                        .fill(isSelected ? Color.orange : Color.blue)
                        .frame(width: 22, height: 22)
                    Image(systemName: "m.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else {
                Circle()
                    .fill(isSelected ? Color.orange : Color.blue.opacity(0.8))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.5 : 1.0)
        .animation(.spring(duration: 0.2), value: isSelected)
    }
}

// MARK: - Map stop preview card (new — uses TransitRouteRow)

struct MapStopPreviewCard: View {
    let stop: Stop
    let schedule: [ScheduleEntry]
    let userLocation: CLLocation?
    let isFavorite: Bool
    let isLoading: Bool
    let onOpenDetail: () -> Void
    let onDismiss: () -> Void
    let onFavoriteToggle: () -> Void

    private var groups: [RouteDeparturesGroup] { schedule.groupedByRouteAndHeadsign(limit: 2) }

    private var walkingInfo: String? {
        guard let loc = userLocation else { return nil }
        let dist = stop.distance(from: loc)
        let walkMin = max(1, Int((dist / 80).rounded()))
        return "\(stop.formattedDistance(from: loc)) · \(walkMin) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().padding(.leading, 14)

            if isLoading {
                VStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { i in
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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if i == 0 { Divider().padding(.leading, 14 + 44 + 12) }
                    }
                }
                .redacted(reason: .placeholder)
            } else if groups.isEmpty {
                Text(schedule.isEmpty ? "Aucun service actif" : "Aucun départ prochain")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else {
                let shown = Array(groups.prefix(3))
                VStack(spacing: 0) {
                    ForEach(shown.indices, id: \.self) { i in
                        TransitRouteRow(group: shown[i])
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if i < shown.count - 1 {
                            Divider().padding(.leading, 14 + 44 + 12)
                        }
                    }
                }
            }

            Button(action: onOpenDetail) {
                HStack(spacing: 6) {
                    Text("Voir tous les horaires")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(stop.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    ProviderBadge(providerId: stop.providerId)
                    if let info = walkingInfo {
                        HStack(spacing: 3) {
                            Image(systemName: "figure.walk")
                                .font(.caption2.weight(.semibold))
                            Text(info)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Button(action: onFavoriteToggle) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color(.systemGray3))
            }
            .buttonStyle(.plain)
        }
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
    }
}
