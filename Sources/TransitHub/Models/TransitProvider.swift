import SwiftUI

// MARK: - Transit Provider
//
// A `TransitProvider` describes a single transit network. They are
// persisted to disk by `UserProvidersStore`; users add them at runtime
// by searching https://mobilitydatabase.org.

struct TransitProvider: Identifiable, Equatable, Codable, Hashable {
    let id: String                 // MDB id, e.g. "mdb-2126"
    var shortName: String          // user-editable — `deriveShortName` only supplies the initial guess
    var fullName: String
    let gtfsFeedURL: URL
    let brandColorHex: String      // RRGGBB
    var supportsRealtime: Bool
    var hasMetro: Bool

    var country: String?
    var city: String?

    // GTFS-Realtime endpoints (optional — provider may have none)
    var rtVehiclePositionsURL: URL?
    var rtTripUpdatesURL: URL?
    var rtServiceAlertsURL: URL?

    // MDB authentication_type: 0 none, 1 query-string key, 2 header key.
    // `rtApiKeyParamName` is the header/query name expected by the RT endpoint.
    var rtAuthType: Int = 0
    var rtApiKeyParamName: String?

    var brandColor: Color { Color(hex: brandColorHex) ?? .blue }

    var needsRealtimeKey: Bool { supportsRealtime && rtAuthType != 0 }
}

// MARK: - Provider Badge
//
// Callers can pass a `TransitProvider` directly, or just a providerId — in
// which case the badge resolves the brand color / short name from the shared
// `UserProvidersStore` via the SwiftUI environment.

struct ProviderBadge: View {
    @EnvironmentObject private var store: UserProvidersStore

    private enum Source { case resolved(TransitProvider); case id(String) }
    private let source: Source
    var font: Font = .caption2.weight(.bold)

    init(provider: TransitProvider, font: Font = .caption2.weight(.bold)) {
        self.source = .resolved(provider)
        self.font = font
    }

    init(providerId: String, font: Font = .caption2.weight(.bold)) {
        self.source = .id(providerId)
        self.font = font
    }

    private var resolved: TransitProvider {
        switch source {
        case .resolved(let p): return p
        case .id(let pid):
            if let match = store.providers.first(where: { $0.id == pid }) { return match }
            // Unknown providerId (e.g. a favorite pointing at a removed provider).
            // Fall back to a neutral chip.
            return TransitProvider(
                id: pid, shortName: pid.uppercased(), fullName: pid,
                gtfsFeedURL: URL(string: "https://example.invalid")!,
                brandColorHex: "6C757D", supportsRealtime: false, hasMetro: false)
        }
    }

    var body: some View {
        let p = resolved
        Text(p.shortName)
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(p.brandColor, in: RoundedRectangle(cornerRadius: 4))
    }
}
