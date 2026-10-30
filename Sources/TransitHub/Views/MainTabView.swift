import SwiftUI

enum AppTab: Hashable {
    case home, map, plan, nearby, routes
}

struct MainTabView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var liveActivityManager: LiveActivityManager
    @StateObject private var locationService = LocationService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $appVM.selectedTab) {
            FavoritesView()
                .tabItem { Label("Accueil", systemImage: "house") }
                .tag(AppTab.home)

            TransitMapView(locationService: locationService)
                .tabItem { Label("Carte", systemImage: "map") }
                .tag(AppTab.map)

            PlanView()
                .tabItem { Label("Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond") }
                .tag(AppTab.plan)

            NearbyView(locationService: locationService)
                .tabItem { Label("À proximité", systemImage: "location") }
                .tag(AppTab.nearby)

            RoutesView()
                .tabItem { Label("Lignes", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.routes)

        }
        .tint(Theme.brandStart)
        .onAppear {
            locationService.requestAuthorization()
        }
        .onChange(of: locationService.location) { _, loc in
            appVM.userLocation = loc
        }
        // Refresh realtime data every 30s — only while the app is active.
        // SwiftUI cancels and re-runs this `.task(id:)` whenever scenePhase
        // changes, which gives us free pause/resume semantics: on background
        // the loop is cancelled, on return to foreground we refresh immediately
        // and resume the 30s cadence.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            liveActivityManager.refreshNow()
            await appVM.refreshRealtime()
            liveActivityManager.applyRealtime(appVM.tripUpdatesByProvider)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                await appVM.refreshRealtime()
                liveActivityManager.applyRealtime(appVM.tripUpdatesByProvider)
            }
        }
    }
}
