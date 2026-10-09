import SwiftUI
import CoreLocation

struct NearbyView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @ObservedObject var locationService: LocationService
    @State private var selectedStop: Stop?
    @State private var schedulesByStop: [String: [ScheduleEntry]] = [:]
    @State private var isLoadingSchedules = false

    var nearestStops: [Stop] {
        guard let loc = locationService.location else { return [] }
        return appVM.nearestStops(to: loc, count: 20)
    }

    private var stopsKey: String {
        nearestStops.prefix(10).map(\.favoriteKey).joined()
    }

    var body: some View {
        NavigationStack {
            Group {
                if providersStore.providers.isEmpty {
                    NoProvidersView()
                } else if !locationService.isAuthorized {
                    locationPermissionPrompt
                } else if locationService.location == nil {
                    ProgressView("Localisation en cours…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stopsScroll
                }
            }
            .navigationTitle("À proximité")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(item: $selectedStop) { stop in
                NavigationStack {
                    StopDetailView(stop: stop)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task(id: stopsKey) {
            await loadSchedules()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            Task { await loadSchedules() }
        }
    }

    // MARK: - Stops list

    private var stopsScroll: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(nearestStops) { stop in
                    Button { selectedStop = stop } label: {
                        TransitStopCard(
                            stop: stop,
                            schedule: schedulesByStop[stop.id] ?? [],
                            userLocation: locationService.location,
                            isFavorite: appVM.isFavorite(stop),
                            isLoading: isLoadingSchedules && schedulesByStop[stop.id] == nil,
                            maxRoutes: 4
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
                    }
                }
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

    // MARK: - Schedule batch loading

    private func loadSchedules() async {
        let stops = Array(nearestStops.prefix(15))
        guard !stops.isEmpty else { return }
        isLoadingSchedules = true
        schedulesByStop = await appVM.loadSchedules(for: stops)
        isLoadingSchedules = false
    }

    // MARK: - Location permission prompt

    private var locationPermissionPrompt: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.slash.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Localisation désactivée")
                .font(.headline)
            Text("Autorisez l'accès à votre position pour voir les arrêts à proximité.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Autoriser la localisation") {
                locationService.requestAuthorization()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
