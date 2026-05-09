import SwiftUI

// MARK: - SettingsView
//
// Lists every configured transit provider with a "+ Add" action that presents
// `AddProviderView` (MobilityDatabase search). Each row drills into
// `ProviderDetailView` for realtime API key, force-update, and removal.

struct SettingsView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore

    @State private var showAddProvider = false
    @State private var databaseSizes: [String: String] = [:]
    @State private var lastImportDates: [String: String] = [:]

    var body: some View {
        Form {
            // MARK: Providers list
            Section {
                if providersStore.providers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aucun fournisseur configuré")
                            .font(.body)
                        Text("Ajoutez un premier réseau de transport depuis le catalogue MobilityDatabase.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(providersStore.providers) { provider in
                        NavigationLink {
                            ProviderDetailView(provider: provider,
                                               databaseSize: databaseSizes[provider.id] ?? "–",
                                               lastImport:    lastImportDates[provider.id] ?? "–",
                                               onChange: { computeProviderInfo() })
                        } label: {
                            providerRow(provider)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            let p = providersStore.providers[i]
                            providersStore.remove(id: p.id)
                        }
                    }
                }

                Button {
                    showAddProvider = true
                } label: {
                    Label("Ajouter un fournisseur", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Fournisseurs de transport")
            } footer: {
                Text("Les flux sont fournis par MobilityDatabase.org.")
            }

            // MARK: App info
            Section("À propos") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Rafraîchissement GTFS") {
                    Text("À expiration du flux").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Réglages")
        .onAppear { computeProviderInfo() }
        .sheet(isPresented: $showAddProvider) {
            AddProviderView()
                .environmentObject(providersStore)
        }
    }

    private func providerRow(_ provider: TransitProvider) -> some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.fullName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                let loc = [provider.city, provider.country].compactMap { $0 }.joined(separator: ", ")
                if !loc.isEmpty {
                    Text(loc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if provider.needsRealtimeKey
                && GTFSRealtimeService.forProvider(provider).apiKey.isEmpty {
                Image(systemName: "key.slash")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    private func computeProviderInfo() {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        for provider in providersStore.providers {
            let db = GTFSDatabase.forProvider(provider)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: db.databaseURL.path),
               let size = attrs[.size] as? Int64 {
                databaseSizes[provider.id] = String(format: "%.1f MB", Double(size) / 1_048_576)
            } else {
                databaseSizes[provider.id] = "–"
            }
            if (try? db.open()) != nil {
                defer { db.close() }
                if let ts = try? db.getMetadata("imported_at"),
                   let epoch = Double(ts) {
                    lastImportDates[provider.id] = fmt.string(from: Date(timeIntervalSince1970: epoch))
                }
            }
        }
    }
}

// MARK: - ProviderDetailView

struct ProviderDetailView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore
    @Environment(\.dismiss) private var dismiss

    let provider: TransitProvider
    let databaseSize: String
    let lastImport: String
    var onChange: () -> Void = {}

    @State private var apiKey: String = ""
    @State private var connectionStatus: GTFSRealtimeService.ConnectionStatus = .idle
    @State private var keySaved = false
    @State private var showClearConfirm = false
    @State private var showRemoveConfirm = false
    @State private var shortNameDraft: String = ""
    @State private var fullNameDraft: String = ""
    @State private var supportsRealtimeDraft = false
    @State private var vehiclePositionsURLDraft = ""
    @State private var tripUpdatesURLDraft = ""
    @State private var serviceAlertsURLDraft = ""
    @State private var authTypeDraft = 0
    @State private var apiKeyParamNameDraft = ""

    private var rtService: GTFSRealtimeService { GTFSRealtimeService.forProvider(provider) }

    private var trimmedShort: String { shortNameDraft.trimmingCharacters(in: .whitespaces) }

    private var rtConfigDirty: Bool {
        supportsRealtimeDraft != provider.supportsRealtime ||
        vehiclePositionsURLDraft != (provider.rtVehiclePositionsURL?.absoluteString ?? "") ||
        tripUpdatesURLDraft      != (provider.rtTripUpdatesURL?.absoluteString      ?? "") ||
        serviceAlertsURLDraft    != (provider.rtServiceAlertsURL?.absoluteString    ?? "") ||
        authTypeDraft            != provider.rtAuthType ||
        apiKeyParamNameDraft     != (provider.rtApiKeyParamName ?? "")
    }
    private var trimmedFull:  String { fullNameDraft.trimmingCharacters(in: .whitespaces) }
    private var nameDirty: Bool {
        !trimmedShort.isEmpty && !trimmedFull.isEmpty &&
        (trimmedShort != provider.shortName || trimmedFull != provider.fullName)
    }

    var body: some View {
        Form {
            // MARK: Identity (editable)
            Section {
                LabeledContent("Nom abrégé") {
                    TextField("ex. STM", text: $shortNameDraft)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                LabeledContent("Nom complet") {
                    TextField("Nom du fournisseur", text: $fullNameDraft)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                if nameDirty {
                    Button("Enregistrer") {
                        var updated = provider
                        updated.shortName = trimmedShort
                        updated.fullName  = trimmedFull
                        providersStore.update(updated)
                        dismissKeyboard()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Identité")
            } footer: {
                Text("Le nom abrégé s'affiche dans la pastille colorée et les filtres.")
            }

            // MARK: Realtime endpoint configuration
            Section {
                Toggle("Activer le temps réel", isOn: $supportsRealtimeDraft)

                if supportsRealtimeDraft {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Positions des véhicules").font(.caption).foregroundStyle(.secondary)
                        TextField("https://…", text: $vehiclePositionsURLDraft)
                            .font(.footnote)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mises à jour des trajets").font(.caption).foregroundStyle(.secondary)
                        TextField("https://…", text: $tripUpdatesURLDraft)
                            .font(.footnote)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Avis de service").font(.caption).foregroundStyle(.secondary)
                        TextField("https://…", text: $serviceAlertsURLDraft)
                            .font(.footnote)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Picker("Authentification", selection: $authTypeDraft) {
                        Text("Aucune").tag(0)
                        Text("Clé API (paramètre URL)").tag(1)
                        Text("Clé API (en-tête HTTP)").tag(2)
                    }
                    if authTypeDraft != 0 {
                        TextField("Nom du paramètre (ex. apikey)", text: $apiKeyParamNameDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if rtConfigDirty {
                    Button("Enregistrer") { saveRTConfig() }
                        .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Temps réel")
            }

            // MARK: Realtime API key (only when auth is required)
            if supportsRealtimeDraft && authTypeDraft != 0 {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField("Clé API \(provider.shortName)", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: apiKey) { _, _ in
                                    connectionStatus = .idle
                                    keySaved = false
                                }
                            if !apiKey.isEmpty {
                                Button {
                                    apiKey = ""
                                    connectionStatus = .idle
                                    keySaved = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        APIKeyStatusBadge(status: connectionStatus, keySaved: keySaved)
                    }

                    HStack(spacing: 12) {
                        Button("Enregistrer") {
                            rtService.apiKey = apiKey
                            keySaved = true
                            connectionStatus = .idle
                            dismissKeyboard()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.isEmpty)

                        Button {
                            rtService.apiKey = apiKey
                            keySaved = true
                            connectionStatus = .testing
                            Task {
                                connectionStatus = await rtService.testConnection()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if case .testing = connectionStatus {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                }
                                Text("Tester")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(apiKey.isEmpty || isTesting)
                    }
                } header: {
                    Text("Données en temps réel")
                } footer: {
                    Text(authHint)
                }
            }

            // MARK: Data management
            Section("Données GTFS") {
                HStack {
                    Label("Base de données", systemImage: "externaldrive")
                    Spacer()
                    Text(databaseSize).foregroundStyle(.secondary).font(.caption)
                }
                HStack {
                    Label("Dernière mise à jour", systemImage: "clock")
                    Spacer()
                    Text(lastImport).foregroundStyle(.secondary).font(.caption)
                }
                Button("Forcer la mise à jour") {
                    Task {
                        try? GTFSDatabase.forProvider(provider).deleteDatabase()
                        appVM.loadData()
                        onChange()
                    }
                }
                .foregroundStyle(.orange)
                Button("Effacer et réimporter", role: .destructive) {
                    showClearConfirm = true
                }
            }

            // MARK: Provider info
            Section("Détails") {
                LabeledContent("Identifiant") {
                    Text(provider.id).foregroundStyle(.secondary)
                        .font(.caption.monospaced())
                }
                if let city = provider.city {
                    LabeledContent("Ville") { Text(city).foregroundStyle(.secondary) }
                }
                if let country = provider.country {
                    LabeledContent("Pays") { Text(country).foregroundStyle(.secondary) }
                }
            }

            // MARK: Remove
            Section {
                Button("Retirer ce fournisseur", role: .destructive) {
                    showRemoveConfirm = true
                }
            }
        }
        .navigationTitle(provider.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = rtService.apiKey
            shortNameDraft = provider.shortName
            fullNameDraft  = provider.fullName
            supportsRealtimeDraft    = provider.supportsRealtime
            vehiclePositionsURLDraft = provider.rtVehiclePositionsURL?.absoluteString ?? ""
            tripUpdatesURLDraft      = provider.rtTripUpdatesURL?.absoluteString      ?? ""
            serviceAlertsURLDraft    = provider.rtServiceAlertsURL?.absoluteString    ?? ""
            authTypeDraft            = provider.rtAuthType
            apiKeyParamNameDraft     = provider.rtApiKeyParamName ?? ""
        }
        .confirmationDialog(
            "Effacer les données locales de \(provider.shortName) et les retélécharger ?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Effacer et réimporter", role: .destructive) {
                try? GTFSDatabase.forProvider(provider).deleteDatabase()
                appVM.loadData()
                onChange()
            }
        }
        .confirmationDialog(
            "Retirer \(provider.shortName) ?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Retirer", role: .destructive) {
                try? GTFSDatabase.forProvider(provider).deleteDatabase()
                providersStore.remove(id: provider.id)
                dismiss()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La base GTFS locale sera supprimée. Vous pourrez réajouter le fournisseur plus tard.")
        }
    }

    private var isTesting: Bool {
        if case .testing = connectionStatus { return true }
        return false
    }

    private var authHint: String {
        if let name = provider.rtApiKeyParamName {
            return "Ce flux requiert un paramètre « \(name) »."
        }
        return "Ce flux requiert une clé d'authentification."
    }

    private func saveRTConfig() {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var updated = provider
        updated.supportsRealtime       = supportsRealtimeDraft
        updated.rtVehiclePositionsURL  = URL(string: trim(vehiclePositionsURLDraft))
        updated.rtTripUpdatesURL       = URL(string: trim(tripUpdatesURLDraft))
        updated.rtServiceAlertsURL     = URL(string: trim(serviceAlertsURLDraft))
        updated.rtAuthType             = authTypeDraft
        let paramName = trim(apiKeyParamNameDraft)
        updated.rtApiKeyParamName      = paramName.isEmpty ? nil : paramName
        providersStore.update(updated)
        dismissKeyboard()
        dismiss()
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil)
    }
}

// MARK: - API Key Status Badge

struct APIKeyStatusBadge: View {
    let status: GTFSRealtimeService.ConnectionStatus
    let keySaved: Bool

    var body: some View {
        Group {
            switch status {
            case .idle:
                if keySaved {
                    Label("Clé enregistrée", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .testing:
                Label("Test en cours…", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .success(let count):
                Label(
                    count == 0
                        ? "Connexion réussie"
                        : "Connexion réussie — \(count) véhicules actifs",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .failure(let msg):
                VStack(alignment: .leading, spacing: 2) {
                    Label("Connexion échouée", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .animation(.easeInOut(duration: 0.2), value: keySaved)
    }
}
