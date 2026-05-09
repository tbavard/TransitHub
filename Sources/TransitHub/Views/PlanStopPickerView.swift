import SwiftUI
import CoreLocation

/// Sheet for picking a trip endpoint. Offers:
/// - "Ma position" (if location is available)
/// - Favorites
/// - Nearby stops
/// - Search results
struct PlanStopPickerView: View {
    @EnvironmentObject var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let onSelect: (PlanEndpoint) -> Void

    @State private var searchText = ""

    private var searchStopResults: [Stop] {
        guard searchText.count >= 2 else { return [] }
        let q = searchText.lowercased()
        return Array(appVM.stops.lazy.filter {
            $0.name.lowercased().contains(q) || $0.id == searchText
        }.prefix(40))
    }

    private var nearbyStops: [Stop] {
        guard let loc = appVM.userLocation else { return [] }
        return appVM.nearestStops(to: loc, count: 10)
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
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                if !searchText.isEmpty {
                    let stops = searchStopResults
                    if stops.isEmpty {
                        Section {
                            Text("Aucun arrêt trouvé")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Résultats") {
                            ForEach(stops) { stop in
                                stopRow(stop)
                            }
                        }
                    }
                } else {
                    if !appVM.favoriteStops.isEmpty {
                        Section("Favoris") {
                            ForEach(appVM.favoriteStops) { stop in
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
            .searchable(text: $searchText, prompt: "Rechercher un arrêt")
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
    private func stopRow(_ stop: Stop) -> some View {
        Button {
            onSelect(.stop(stop))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                    .foregroundStyle(stop.isStation ? .blue : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ProviderBadge(providerId: stop.providerId)
                        if let loc = appVM.userLocation {
                            Text(stop.formattedDistance(from: loc))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
