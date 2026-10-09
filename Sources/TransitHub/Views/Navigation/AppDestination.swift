import SwiftUI

// MARK: - App destinations
//
// Every detail screen reachable by push. Each NavigationStack registers
// `.appDestinations()`, so a route or a stop opens the same way (push, with a
// back button that returns to where the user came from) whichever tab it was
// tapped in — and a stop can lead to a route and back.

enum AppDestination: Hashable {
    case route(Route)
    /// `context` is set when the stop is opened from a route's detail.
    case stop(Stop, context: StopRouteContext? = nil)
}

extension View {
    /// Registers the push destinations for `AppDestination` values.
    func appDestinations() -> some View {
        navigationDestination(for: AppDestination.self) { destination in
            switch destination {
            case .route(let route):
                RouteDetailView(route: route)
            case .stop(let stop, let context):
                StopDetailView(stop: stop, routeContext: context)
            }
        }
    }
}
