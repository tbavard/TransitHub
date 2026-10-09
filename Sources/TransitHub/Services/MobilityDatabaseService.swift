import Foundation

// MARK: - MobilityDatabaseService
//
// Thin async client for https://api.mobilitydatabase.org/v1/. The bundled
// refresh token lives in `Resources/MobilityDBConfig.plist` (MDBRefreshToken).
// Access tokens are cached in memory until their expiration and the service
// re-negotiates when a 401 is returned.

@MainActor
final class MobilityDatabaseService {
    static let shared = MobilityDatabaseService()

    enum MDBError: LocalizedError {
        case notConfigured
        case http(Int, String?)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Catalogue non configuré (MobilityDBConfig.plist manquant)"
            case .http(let code, let msg): return "HTTP \(code)" + (msg.map { " — \($0)" } ?? "")
            case .decode(let msg): return "Réponse invalide: \(msg)"
            }
        }
    }

    private let base = URL(string: "https://api.mobilitydatabase.org/v1/")!
    private let refreshToken: String?
    private var accessToken: String?
    private var accessExpiry: Date?

    private init() {
        self.refreshToken = Self.loadRefreshToken()
    }

    var isConfigured: Bool {
        guard let t = refreshToken else { return false }
        return !t.isEmpty
    }

    // MARK: Public API

    func searchGtfs(query: String, limit: Int = 25) async throws -> [MDBFeedSearchResult] {
        var comps = URLComponents(url: base.appendingPathComponent("search"),
                                  resolvingAgainstBaseURL: false)!
        // Note: we intentionally don't filter on status — many valid feeds
        // (including STM at the time of writing) are flagged "inactive" by
        // MobilityDatabase despite having a usable `latest_dataset`. Status is
        // surfaced in the UI so the user can judge.
        comps.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            URLQueryItem(name: "data_type",    value: "gtfs"),
            URLQueryItem(name: "limit",        value: String(limit))
        ]
        let data = try await authed(url: comps.url!)
        do {
            let decoded = try JSONDecoder().decode(MDBSearchResponse.self, from: data)
            return decoded.results ?? []
        } catch {
            throw MDBError.decode(error.localizedDescription)
        }
    }

    func fetchGtfsFeed(id: String) async throws -> MDBGtfsFeed {
        let url = base.appendingPathComponent("gtfs_feeds").appendingPathComponent(id)
        let data = try await authed(url: url)
        do { return try JSONDecoder().decode(MDBGtfsFeed.self, from: data) }
        catch { throw MDBError.decode(error.localizedDescription) }
    }

    func fetchRelatedRT(gtfsId: String) async throws -> [MDBGtfsRTFeed] {
        let url = base.appendingPathComponent("gtfs_feeds")
            .appendingPathComponent(gtfsId)
            .appendingPathComponent("gtfs_rt_feeds")
        let data = try await authed(url: url)
        do { return try JSONDecoder().decode([MDBGtfsRTFeed].self, from: data) }
        catch { throw MDBError.decode(error.localizedDescription) }
    }

    /// Maps a GTFS feed + its RT cousins to a `TransitProvider` the rest of the
    /// app already understands. Returns nil when the feed has no downloadable
    /// GTFS dataset URL (some catalogue entries are stubs pending ingestion).
    func buildProvider(from gtfs: MDBGtfsFeed, rt: [MDBGtfsRTFeed]) -> TransitProvider? {
        // MobilityDatabase rehosts each feed on their own CDN via `hosted_url`,
        // but those snapshots are refreshed infrequently and routinely go stale
        // (STM's mirror was 4+ months behind when tested). The producer's
        // direct URL is continuously updated, so prefer it when it looks like
        // an http(s) endpoint we can actually download from.
        let candidates: [String?] = [
            gtfs.source_info?.producer_url,
            gtfs.latest_dataset?.hosted_url
        ]
        guard let gtfsURL = candidates
            .compactMap({ $0 })
            .first(where: { $0.hasPrefix("http") })
            .flatMap(URL.init(string:))
        else { return nil }

        let loc = gtfs.locations?.first
        let providerName = gtfs.provider ?? gtfs.feed_name ?? gtfs.id

        let rtVp = rt.first(where: { $0.entity_types?.contains("vp") == true })
        let rtTu = rt.first(where: { $0.entity_types?.contains("tu") == true })
        let rtSa = rt.first(where: { $0.entity_types?.contains("sa") == true })

        let representativeRT = rtVp ?? rtTu ?? rtSa ?? rt.first
        let rtAuthType   = representativeRT?.source_info?.authentication_type ?? 0
        let rtKeyName    = representativeRT?.source_info?.api_key_parameter_name

        return TransitProvider(
            id: gtfs.id,
            shortName: Self.deriveShortName(from: providerName),
            fullName: providerName,
            gtfsFeedURL: gtfsURL,
            brandColorHex: Self.paletteColor(for: gtfs.id),
            supportsRealtime: !rt.isEmpty,
            hasMetro: false,
            country: loc?.country ?? loc?.country_code,
            city: loc?.municipality ?? loc?.subdivision_name,
            rtVehiclePositionsURL: rtVp?.source_info?.producer_url.flatMap(URL.init(string:)),
            rtTripUpdatesURL:      rtTu?.source_info?.producer_url.flatMap(URL.init(string:)),
            rtServiceAlertsURL:    rtSa?.source_info?.producer_url.flatMap(URL.init(string:)),
            rtAuthType: rtAuthType,
            rtApiKeyParamName: rtKeyName
        )
    }

    // MARK: Auth

    private func accessBearer() async throws -> String {
        guard let refresh = refreshToken, !refresh.isEmpty else { throw MDBError.notConfigured }
        if let token = accessToken, let expiry = accessExpiry,
           expiry.timeIntervalSinceNow > 30 {
            return token
        }
        let url = base.appendingPathComponent("tokens/access")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw MDBError.http(0, "No response")
        }
        guard http.statusCode == 200 else {
            throw MDBError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        let token = try JSONDecoder().decode(MDBTokenResponse.self, from: data)
        accessToken = token.access_token
        accessExpiry = token.expiration_datetime_utc.flatMap(Self.parseExpiry)
            ?? Date().addingTimeInterval(55 * 60)
        return token.access_token
    }

    private func authed(url: URL) async throws -> Data {
        let bearer = try await accessBearer()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw MDBError.http(0, "No response")
        }
        if http.statusCode == 401 {
            // Token may have been invalidated mid-session — drop cache and retry once.
            accessToken = nil; accessExpiry = nil
            let retryBearer = try await accessBearer()
            var retry = URLRequest(url: url)
            retry.setValue("Bearer \(retryBearer)", forHTTPHeaderField: "Authorization")
            retry.setValue("application/json", forHTTPHeaderField: "Accept")
            retry.timeoutInterval = 15
            let (d2, r2) = try await URLSession.shared.data(for: retry)
            guard let h2 = r2 as? HTTPURLResponse, h2.statusCode == 200 else {
                throw MDBError.http((r2 as? HTTPURLResponse)?.statusCode ?? 0,
                                    String(data: d2, encoding: .utf8))
            }
            return d2
        }
        guard http.statusCode == 200 else {
            throw MDBError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    // MARK: Helpers

    private static func loadRefreshToken() -> String? {
        guard let url = Bundle.main.url(forResource: "MobilityDBConfig", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let token = dict["MDBRefreshToken"] as? String
        else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseExpiry(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// Uppercase first word + any leading capitals — max 5 chars.
    /// Examples: "Société de transport de Montréal" → "STM" is already known
    /// (seeded). "Metropolitan Transit Authority" → "MTA". "TransLink" → "TRANS".
    private static func deriveShortName(from name: String) -> String {
        let caps = name.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }
        if caps.count >= 2, caps.count <= 5 {
            return String(String.UnicodeScalarView(caps))
        }
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return String(first.prefix(5)).uppercased()
    }

    /// Deterministic palette pick so every new provider gets a stable badge color.
    private static func paletteColor(for id: String) -> String {
        let palette = [
            "1F77B4", "D62728", "2CA02C", "FF7F0E", "9467BD",
            "8C564B", "E377C2", "17BECF", "BCBD22", "7F7F7F"
        ]
        let h = abs(id.hashValue)
        return palette[h % palette.count]
    }
}
