import Foundation

// MARK: - MobilityDatabase.org response models
//
// Covers only the subset of https://api.mobilitydatabase.org/v1/ we consume:
// - POST /tokens/access (access-token exchange)
// - GET  /search
// - GET  /gtfs_feeds/{id}
// - GET  /gtfs_feeds/{id}/gtfs_rt_feeds

// MARK: Token

struct MDBTokenResponse: Decodable {
    let access_token: String
    let expiration_datetime_utc: String?
    let token_type: String?
}

// MARK: Search

struct MDBSearchResponse: Decodable {
    let total: Int?
    let results: [MDBFeedSearchResult]?
}

struct MDBFeedSearchResult: Decodable, Identifiable, Equatable {
    let id: String
    let data_type: String?
    let provider: String?
    let feed_name: String?
    let status: String?
    let official: Bool?
    let locations: [MDBLocation]?
    let source_info: MDBSourceInfo?
    let latest_dataset: MDBLatestDataset?
    /// Only present on GTFS-RT results (we filter to data_type=gtfs, but keep it safe)
    let entity_types: [String]?

    var primaryLocation: MDBLocation? { locations?.first }
}

// MARK: Feed detail / RT

struct MDBGtfsFeed: Decodable {
    let id: String
    let data_type: String?
    let provider: String?
    let feed_name: String?
    let official: Bool?
    let locations: [MDBLocation]?
    let source_info: MDBSourceInfo?
    let latest_dataset: MDBLatestDataset?
    let feed_contact_email: String?
    let status: String?
}

struct MDBGtfsRTFeed: Decodable {
    let id: String
    let data_type: String?
    let provider: String?
    let entity_types: [String]?
    let locations: [MDBLocation]?
    let source_info: MDBSourceInfo?
    let feed_references: [String]?
}

struct MDBLocation: Decodable, Equatable, Hashable {
    let country_code: String?
    let country: String?
    let subdivision_name: String?
    let municipality: String?
}

struct MDBSourceInfo: Decodable, Equatable {
    let producer_url: String?
    let authentication_type: Int?     // 0 none, 1 query-string key, 2 header key
    let authentication_info_url: String?
    let api_key_parameter_name: String?
    let license_url: String?
}

struct MDBLatestDataset: Decodable, Equatable {
    let id: String?
    let hosted_url: String?
    let downloaded_at: String?
    let hash: String?
    let service_date_range_start: String?
    let service_date_range_end: String?
    let agency_timezone: String?
    let zipped_folder_size_mb: Double?
}
