import Foundation
import MapKit

/// Address / place autocomplete for the trip planner (Apple MapKit, no API key).
@MainActor
final class PlaceSearcher: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {

    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Biases suggestions toward the area around `center` (the transit network).
    func setRegion(around center: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: center, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 {
            suggestions = []
            completer.queryFragment = ""
        } else {
            completer.queryFragment = trimmed
        }
    }

    /// Resolves a suggestion to a coordinate.
    func resolve(_ completion: MKLocalSearchCompletion) async -> PlaceRef? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        return PlaceRef(name: completion.title, subtitle: completion.subtitle,
                        lat: coordinate.latitude, lon: coordinate.longitude)
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
