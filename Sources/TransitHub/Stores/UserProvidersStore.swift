import Foundation
import Combine
import os

// MARK: - UserProvidersStore
//
// Persists the user's configured list of transit providers to
// `Documents/user_providers.json`. The rest of the app reads
// `providers` as a @Published so UI reacts to additions/removals.

@MainActor
final class UserProvidersStore: ObservableObject {

    @Published private(set) var providers: [TransitProvider] = []

    private static let logger = Logger(subsystem: "com.transithub", category: "UserProvidersStore")

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("user_providers.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let arr  = try? JSONDecoder().decode([TransitProvider].self, from: data)
        else { return }
        providers = arr
    }

    func add(_ provider: TransitProvider) {
        guard !providers.contains(where: { $0.id == provider.id }) else { return }
        providers.append(provider)
        save()
    }

    func update(_ provider: TransitProvider) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx] = provider
        save()
    }

    func remove(id: String) {
        providers.removeAll { $0.id == id }
        save()
    }

    func contains(id: String) -> Bool {
        providers.contains { $0.id == id }
    }

    func provider(id: String) -> TransitProvider? {
        providers.first { $0.id == id }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(providers)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
