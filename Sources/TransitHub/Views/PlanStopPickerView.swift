import SwiftUI
import CoreLocation
import MapKit

/// Sheet for picking a trip endpoint. Offers:
/// - "Ma position" (if location is available)
/// - Favorites
/// - Nearby stops
/// - Search results
struct PlanStopPickerView: View {
    @EnvironmentObject var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// Only this network's stops are offered (one network per search).
    let providerId: String
    let onSelect: (PlanEndpoint) -> Void

    @State private var searchText = ""
    @StateObject private var places = PlaceSearcher()
    @State private var isResolvingPlace = false

    private var searchStopResults: [Stop] {
        guard searchText.count >= 2 else { return [] }
        let q = searchText.lowercased()
        return Array(appVM.stops.lazy.filter {
            $0.providerId == providerId
                && ($0.name.lowercased().contains(q) || $0.id == searchText)
        }.prefix(40))
    }

    private var favoriteStops: [Stop] {
        appVM.favoriteStops.filter { $0.providerId == providerId }
    }

    private var nearbyStops: [Stop] {
        guard let loc = appVM.userLocation else { return [] }
        return Array(appVM.nearestStops(to: loc, count: 60)
            .filter { $0.providerId == providerId }
            .prefix(10))
    }

    var body: some View {
        NavigationStack {
            List {
                if appVM.userLocation != nil {
                    Section {
                        Button {
                            onSelect(.userLocation)
                            dismiss()
                        } label: {
                            Label {
                                Text("Ma position")
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(Theme.brandStart)
                            }
                        }
                    }
                }

                if !searchText.isEmpty {
                    let stops = searchStopResults
                    if !places.suggestions.isEmpty {
                        Section("Lieux et adresses") {
                            ForEach(places.suggestions.prefix(6), id: \.self) { suggestion in
                                placeRow(suggestion)
                            }
                        }
                    }
                    if !stops.isEmpty {
                        Section("Arrêts") {
                            ForEach(stops) { stop in
                                stopRow(stop)
                            }
                        }
                    }
                    if stops.isEmpty && places.suggestions.isEmpty {
                        Section {
                            Text("Aucun résultat")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    if !favoriteStops.isEmpty {
                        Section("Favoris") {
                            ForEach(favoriteStops) { stop in
                                stopRow(stop)
                            }
                        }
                    }

                    if !nearbyStops.isEmpty {
                        Section("À proximité") {
                            ForEach(nearbyStops) { stop in
                                stopRow(stop)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Adresse, lieu ou arrêt")
            .onChange(of: searchText) { _, text in places.update(query: text) }
            .onAppear {
                let center = appVM.userLocation?.coordinate
                    ?? appVM.stops.first(where: { $0.providerId == providerId })?.coordinate
                if let center { places.setRegion(around: center) }
            }
            .overlay { if isResolvingPlace { ProgressView() } }
            .navigationTitle("Choisir un lieu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func placeRow(_ suggestion: MKLocalSearchCompletion) -> some View {
        Button {
            guard !isResolvingPlace else { return }
            isResolvingPlace = true
            Task {
                let place = await places.resolve(suggestion)
                isResolvingPlace = false
                if let place {
                    onSelect(.place(place))
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(Theme.statusCritical)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(suggestion.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func stopRow(_ stop: Stop) -> some View {
        Button {
            onSelect(.stop(stop))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: stop.symbolName).accessibilityHidden(true)
                    .foregroundStyle(stop.isStation ? Theme.brandStart : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let loc = appVM.userLocation {
                        Text(stop.formattedDistance(from: loc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
