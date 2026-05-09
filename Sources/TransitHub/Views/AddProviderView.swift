import SwiftUI

// MARK: - AddProviderView
//
// Sheet presented from Settings. Lets the user search the MobilityDatabase.org
// catalogue for GTFS feeds and add one to their `UserProvidersStore`. The
// search input is debounced so we don't flood the API on every keystroke.

struct AddProviderView: View {
    @EnvironmentObject var providersStore: UserProvidersStore
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [MDBFeedSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    @State private var pendingAdd: MDBFeedSearchResult?
    @State private var isAdding = false

    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Ajouter un fournisseur")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { dismiss() }
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Ville, agence, pays…")
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }
                .onDisappear { searchTask?.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !MobilityDatabaseService.shared.isConfigured {
            ContentUnavailableView(
                "Catalogue indisponible",
                systemImage: "xmark.icloud",
                description: Text("Le jeton MobilityDatabase n'est pas configuré dans l'application.")
            )
        } else if let err = errorMessage {
            ContentUnavailableView(
                "Erreur",
                systemImage: "exclamationmark.triangle",
                description: Text(err)
            )
        } else if isSearching {
            ProgressView("Recherche…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.isEmpty {
            hintView
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            resultsList
        }
    }

    private var hintView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tram.circle")
                .font(.system(size: 52))
                .foregroundStyle(.blue)
            Text("Recherchez un réseau de transport")
                .font(.headline)
            Text("Tapez un nom de ville, d'agence ou un code pays (ex: Paris, RATP, CA) pour trouver des flux GTFS publics.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        List {
            ForEach(results) { result in
                Button {
                    pendingAdd = result
                } label: {
                    resultRow(result)
                }
                .disabled(providersStore.contains(id: result.id))
            }
        }
        .listStyle(.plain)
        .confirmationDialog("Ajouter ce fournisseur ?",
                            isPresented: Binding(
                                get: { pendingAdd != nil },
                                set: { if !$0 { pendingAdd = nil } }),
                            presenting: pendingAdd) { result in
            Button("Ajouter \(result.provider ?? result.feed_name ?? result.id)") {
                Task { await add(result) }
            }
            Button("Annuler", role: .cancel) { pendingAdd = nil }
        } message: { result in
            Text(descriptionLine(for: result))
        }
        .overlay {
            if isAdding {
                ProgressView("Ajout en cours…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func resultRow(_ r: MDBFeedSearchResult) -> some View {
        let title = r.provider ?? r.feed_name ?? r.id
        let loc = r.primaryLocation
        let locationLine = [loc?.municipality, loc?.subdivision_name, loc?.country ?? loc?.country_code]
            .compactMap { $0 }.joined(separator: ", ")
        let alreadyAdded = providersStore.contains(id: r.id)

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if !locationLine.isEmpty {
                    Text(locationLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if r.official == true {
                        Text("Officiel")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    if let status = r.status, status != "active" {
                        Text(status.capitalized)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if alreadyAdded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
    }

    private func descriptionLine(for r: MDBFeedSearchResult) -> String {
        let loc = r.primaryLocation
        let place = [loc?.municipality, loc?.country_code].compactMap { $0 }.joined(separator: ", ")
        if place.isEmpty { return "L'application téléchargera le flux GTFS lors de la prochaine initialisation." }
        return "\(place) — téléchargement du flux GTFS lors de la prochaine initialisation."
    }

    // MARK: - Search

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            errorMessage = nil
            return
        }

        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ q: String) async {
        isSearching = true
        errorMessage = nil
        do {
            let r = try await MobilityDatabaseService.shared.searchGtfs(query: q)
            if Task.isCancelled { return }
            results = r
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
        isSearching = false
    }

    // MARK: - Add

    private func add(_ result: MDBFeedSearchResult) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let svc = MobilityDatabaseService.shared
            let feed = try await svc.fetchGtfsFeed(id: result.id)
            let rt   = (try? await svc.fetchRelatedRT(gtfsId: result.id)) ?? []
            guard let provider = svc.buildProvider(from: feed, rt: rt) else {
                errorMessage = "Ce flux n'a pas encore de fichier GTFS téléchargeable."
                return
            }
            providersStore.add(provider)
            pendingAdd = nil
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
