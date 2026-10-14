import Foundation
import ZIPFoundation

// MARK: - Line-by-line streaming reader (avoids loading huge files into memory)

final class LineReader {
    private let handle: FileHandle
    private var buffer = Data(capacity: 65_536)
    private let newline = UInt8(ascii: "\n")

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func nextLine() -> String? {
        while true {
            if let idx = buffer.firstIndex(of: newline) {
                let lineData = buffer[..<idx]
                buffer.removeSubrange(...idx)
                var s = String(data: lineData, encoding: .utf8) ?? ""
                if s.hasSuffix("\r") { s.removeLast() }
                return s
            }
            let chunk = handle.readData(ofLength: 65_536)
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                let s = (String(data: buffer, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = Data()
                return s.isEmpty ? nil : s
            }
            buffer.append(chunk)
        }
    }
}

// MARK: - CSV field splitter (handles quoted fields)

func splitCSV(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if c == "\"" {
            let next = line.index(after: i)
            if inQuotes && next < line.endIndex && line[next] == "\"" {
                current.append("\"")
                i = line.index(after: next)
                continue
            }
            inQuotes.toggle()
        } else if c == "," && !inQuotes {
            fields.append(current)
            current = ""
        } else {
            current.append(c)
        }
        i = line.index(after: i)
    }
    fields.append(current)
    return fields
}

// MARK: - GTFSService

final class GTFSService {

    // MARK: Factory

    private static let lock = NSLock()
    private static var instances: [String: GTFSService] = [:]

    static func forProvider(_ provider: TransitProvider) -> GTFSService {
        lock.lock(); defer { lock.unlock() }
        if let existing = instances[provider.id] { return existing }
        let new = GTFSService(provider: provider)
        instances[provider.id] = new
        return new
    }

    private let provider: TransitProvider
    private var gtfsZipURL: URL { provider.gtfsFeedURL }

    private init(provider: TransitProvider) {
        self.provider = provider
    }

    // MARK: - Public API

    /// Returns true when the local database is present and its schedule data has
    /// not yet expired.
    ///
    /// Preferred path: compare today against the `feed_end_date` stored at import
    /// time (derived from the MAX end_date in `calendar`/`calendar_dates`). The
    /// database is considered stale one day before the feed's last covered date so
    /// a new feed is fetched before the app starts returning empty schedules.
    ///
    /// Fallback (legacy databases without `feed_end_date`): stale after 7 days.
    func isDatabaseFresh() -> Bool {
        let db = GTFSDatabase.forProvider(provider)
        guard db.exists else { return false }
        do {
            try db.open()
            defer { db.close() }
            guard let ts = try db.getMetadata("imported_at"),
                  let epoch = Double(ts) else { return false }

            // Databases built by an older importer must be rebuilt.
            guard try db.getMetadata("data_version") == "\(GTFSDatabase.dataVersion)" else {
                return false
            }

            let today = FeedPeriodSelector.dayKey()

            // An archived snapshot stands in for a producer feed that starts
            // later: keep it until that day (or its own end, if earlier).
            if let upcoming = try db.getMetadata("upcoming_feed_start") {
                let end = try db.getMetadata("feed_end_date") ?? upcoming
                return today < upcoming && today <= end
            }

            // Future-only data (no snapshot covered today at import time, or a
            // database imported before this logic existed): retry the archive
            // lookup, at most every 12 h.
            if let start = try db.fetchFeedStartDate(), start > today {
                let checked = Double(try db.getMetadata("archive_checked_at") ?? "") ?? 0
                return Date().timeIntervalSince1970 - checked < 12 * 3600
            }

            if let endStr = try db.getMetadata("feed_end_date"),
               let endDate = Self.parseGtfsDate(endStr) {
                // Refresh 1 day before the feed actually expires.
                return Date() < endDate.addingTimeInterval(-86_400)
            }

            // Legacy fallback: 7-day age limit.
            return Date().timeIntervalSince1970 - epoch < 7 * 24 * 3600
        } catch {
            return false
        }
    }

    private static func parseGtfsDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    /// Downloads GTFS, extracts, imports into SQLite.  Reports progress via `onProgress`.
    ///
    /// When the producer's feed only starts in the future (the agency already
    /// published its next period), the MobilityDatabase snapshot covering
    /// today is installed instead, until the new period begins.
    func downloadAndImport(onProgress: @Sendable @escaping (Double, String) -> Void) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gtfs_\(provider.id)_\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        onProgress(0.0, String(localized: "gtfs.downloading"))
        let producerRoot = try await downloadAndExtract(
            gtfsZipURL, into: workDir.appendingPathComponent("producer", isDirectory: true))

        // Cheap peek at the (tiny) calendar files before the heavy import.
        let today = FeedPeriodSelector.dayKey()
        var root = producerRoot
        var metadata: [String: String] = [:]
        if let producerStart = Self.peekStartDay(in: producerRoot), producerStart > today {
            if let archive = await coveringArchive(for: today),
               let archiveURL = archive.hosted_url.flatMap(URL.init(string:)),
               let archiveRoot = try? await downloadAndExtract(
                   archiveURL, into: workDir.appendingPathComponent("archive", isDirectory: true)) {
                root = archiveRoot
                // Keep the snapshot only until the producer's period begins.
                metadata["upcoming_feed_start"] = producerStart
                metadata["feed_source"] = "mdb-archive:\(archive.id ?? "?")"
            } else {
                // Nothing covers today: import the future feed (the UI says
                // when service starts) and retry the archive lookup later.
                metadata["archive_checked_at"] = "\(Date().timeIntervalSince1970)"
            }
        }

        onProgress(0.30, String(localized: "gtfs.extracting"))
        do {
            try await importExtracted(root: root, metadata: metadata, onProgress: onProgress)
        } catch _ where root != producerRoot {
            // A broken archive must not cost the user their schedules: fall
            // back to the producer's (future) feed and retry later.
            try await importExtracted(
                root: producerRoot,
                metadata: ["archive_checked_at": "\(Date().timeIntervalSince1970)"],
                onProgress: onProgress)
        }
    }

    /// Streams `url` to disk (never in memory), unzips it into `dir` and
    /// returns the folder that actually holds the .txt files.
    private func downloadAndExtract(_ url: URL, into dir: URL) async throws -> URL {
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GTFSError.downloadError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipTmp = dir.appendingPathComponent("gtfs.zip")
        try FileManager.default.moveItem(at: downloadedURL, to: zipTmp)
        try FileManager.default.unzipItem(at: zipTmp, to: dir)
        // Free the zip immediately — the extracted text files are all we need.
        try? FileManager.default.removeItem(at: zipTmp)

        // Some producers (notably MDB-rehosted archives) nest the .txt files
        // inside a subfolder rather than at the archive root. Resolve the
        // actual GTFS root before importing, otherwise every importer would
        // silently skip its file via `openCSV` returning nil.
        guard let gtfsRoot = Self.findGtfsRoot(in: dir) else {
            throw GTFSError.downloadError(String(localized: "gtfs.error.invalid_archive"))
        }
        return gtfsRoot
    }

    /// The MobilityDatabase snapshot of this feed covering `day`, if any.
    /// Best effort: no catalogue token / network error → nil.
    private func coveringArchive(for day: String) async -> MDBLatestDataset? {
        guard let datasets = await Self.fetchArchives(feedId: provider.id) else { return nil }
        return FeedPeriodSelector.covering(datasets, day: day)
    }

    /// MobilityDatabaseService is main-actor isolated (shared token cache);
    /// the import runs off the main actor, so hop over for this one call.
    @MainActor
    private static func fetchArchives(feedId: String) async -> [MDBLatestDataset]? {
        let mdb = MobilityDatabaseService.shared
        guard mdb.isConfigured else { return nil }
        return try? await mdb.fetchDatasets(feedId: feedId)
    }

    /// First service day declared by extracted calendar files ("yyyyMMdd").
    private static func peekStartDay(in root: URL) -> String? {
        func column(_ file: String, _ name: String, keepingRows keep: (([String], [String: Int]) -> Bool)? = nil) -> [String] {
            guard let reader = try? LineReader(url: root.appendingPathComponent(file)),
                  var header = reader.nextLine() else { return [] }
            if header.hasPrefix("\u{FEFF}") { header = String(header.dropFirst()) }
            let idx = Dictionary(splitCSV(header).enumerated().map {
                ($0.element.trimmingCharacters(in: .whitespaces), $0.offset)
            }, uniquingKeysWith: { a, _ in a })
            guard let col = idx[name] else { return [] }
            var out: [String] = []
            while let line = reader.nextLine() {
                let v = splitCSV(line)
                guard col < v.count, keep?(v, idx) ?? true else { continue }
                out.append(v[col].trimmingCharacters(in: .whitespaces))
            }
            return out
        }
        let added = column("calendar_dates.txt", "date") { v, idx in
            guard let t = idx["exception_type"], t < v.count else { return false }
            return v[t].trimmingCharacters(in: .whitespaces) == "1"
        }
        return FeedPeriodSelector.startDay(
            calendarStartDates: column("calendar.txt", "start_date"),
            addedExceptionDates: added)
    }

    /// Imports an extracted GTFS folder into a fresh database.
    private func importExtracted(
        root gtfsRoot: URL,
        metadata extraMetadata: [String: String],
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        onProgress(0.35, String(localized: "gtfs.creating_db"))

        // Delete old DB and reimport
        let db = GTFSDatabase.forProvider(provider)
        try db.deleteDatabase()
        try db.open()
        defer { db.close() }
        try db.createSchema()

        // Import files in order
        try await importRoutes(dir: gtfsRoot, db: db, onProgress: { p in
            onProgress(0.35 + p * 0.05, String(localized: "gtfs.importing_routes"))
        })
        try await importStops(dir: gtfsRoot, db: db, onProgress: { p in
            onProgress(0.40 + p * 0.05, String(localized: "gtfs.importing_stops"))
        })
        try await importTrips(dir: gtfsRoot, db: db, onProgress: { p in
            onProgress(0.45 + p * 0.10, String(localized: "gtfs.importing_trips"))
        })
        try await importCalendar(dir: gtfsRoot, db: db)
        try await importCalendarDates(dir: gtfsRoot, db: db)

        onProgress(0.55, String(localized: "gtfs.importing_stoptimes"))
        try await importStopTimes(dir: gtfsRoot, db: db, onProgress: { p in
            onProgress(0.55 + p * 0.43, String(format: String(localized: "gtfs.importing_stoptimes_progress"), Int(p * 100)))
        })
        try db.interpolateMissingStopTimes()

        // Validate every table the schedule query depends on has rows — a wrong
        // ZIP layout makes `openCSV` return nil and every importer silently
        // no-ops, which would otherwise surface only as blank schedules.
        for table in ["routes", "stops", "trips", "stop_times"] {
            if try db.countRows(in: table) == 0 {
                throw GTFSError.parseError(String(format: String(localized: "gtfs.error.empty_table"), table))
            }
        }
        // fetchActiveServiceIds() reads from both tables, but a feed only needs
        // one of them populated (some agencies express service exclusively via
        // calendar_dates overrides).
        let calendarRows = try db.countRows(in: "calendar")
        let calendarDatesRows = try db.countRows(in: "calendar_dates")
        if calendarRows == 0 && calendarDatesRows == 0 {
            throw GTFSError.parseError(String(localized: "gtfs.error.no_calendar"))
        }

        // Mark completion — also persist the feed's coverage end date so
        // isDatabaseFresh() can expire based on actual data, not a fixed interval.
        try db.setMetadata("imported_at", "\(Date().timeIntervalSince1970)")
        try db.setMetadata("data_version", "\(GTFSDatabase.dataVersion)")
        if let endDate = try? db.fetchFeedEndDate() {
            try db.setMetadata("feed_end_date", endDate)
        }
        for (key, value) in extraMetadata {
            try db.setMetadata(key, value)
        }

        onProgress(1.0, String(localized: "gtfs.ready"))
    }

    // MARK: - File importers

    private func importRoutes(dir: URL, db: GTFSDatabase, onProgress: (Double) -> Void) async throws {
        try importCSVFile(named: "routes.txt", in: dir, to: db) { v, idx in
            try db.insertRoute(Route(
                gtfsId:        field(v, idx, "route_id"),
                agencyId:  field(v, idx, "agency_id"),
                shortName: field(v, idx, "route_short_name"),
                longName:  field(v, idx, "route_long_name"),
                type:      Int(field(v, idx, "route_type")) ?? 3,
                color:     field(v, idx, "route_color"),
                textColor: field(v, idx, "route_text_color")
            ))
        }
        onProgress(1.0)
    }

    private func importStops(dir: URL, db: GTFSDatabase, onProgress: (Double) -> Void) async throws {
        try importCSVFile(named: "stops.txt", in: dir, to: db) { v, idx in
            let parent = field(v, idx, "parent_station")
            try db.insertStop(Stop(
                id:            field(v, idx, "stop_id"),
                name:          field(v, idx, "stop_name"),
                lat:           Double(field(v, idx, "stop_lat")) ?? 0,
                lon:           Double(field(v, idx, "stop_lon")) ?? 0,
                locationType:  Int(field(v, idx, "location_type")) ?? 0,
                parentStation: parent.isEmpty ? nil : parent
            ))
        }
        onProgress(1.0)
    }

    private func importTrips(dir: URL, db: GTFSDatabase, onProgress: (Double) -> Void) async throws {
        try importCSVFile(named: "trips.txt", in: dir, to: db) { v, idx in
            try db.insertTrip(
                id:          field(v, idx, "trip_id"),
                routeId:     field(v, idx, "route_id"),
                serviceId:   field(v, idx, "service_id"),
                headsign:    field(v, idx, "trip_headsign"),
                directionId: Int(field(v, idx, "direction_id")) ?? 0
            )
        }
        onProgress(1.0)
    }

    private func importCalendar(dir: URL, db: GTFSDatabase) async throws {
        try importCSVFile(named: "calendar.txt", in: dir, to: db) { v, idx in
            try db.insertCalendar(ServiceCalendar(
                serviceId:  field(v, idx, "service_id"),
                monday:    field(v, idx, "monday") == "1",
                tuesday:   field(v, idx, "tuesday") == "1",
                wednesday: field(v, idx, "wednesday") == "1",
                thursday:  field(v, idx, "thursday") == "1",
                friday:    field(v, idx, "friday") == "1",
                saturday:  field(v, idx, "saturday") == "1",
                sunday:    field(v, idx, "sunday") == "1",
                startDate: field(v, idx, "start_date"),
                endDate:   field(v, idx, "end_date")
            ))
        }
    }

    private func importCalendarDates(dir: URL, db: GTFSDatabase) async throws {
        try importCSVFile(named: "calendar_dates.txt", in: dir, to: db) { v, idx in
            try db.insertCalendarException(
                serviceId: field(v, idx, "service_id"),
                date:      field(v, idx, "date"),
                type:      Int(field(v, idx, "exception_type")) ?? 1
            )
        }
    }

    private func importStopTimes(dir: URL, db: GTFSDatabase, onProgress: @escaping (Double) -> Void) async throws {
        guard let csv = openCSV(named: "stop_times.txt", in: dir) else { return }

        let fileURL = dir.appendingPathComponent("stop_times.txt")
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        try db.beginTransaction()
        try db.prepareStopTimeInsert()

        var count = 0
        let batchSize = 50_000

        while let line = csv.reader.nextLine() {
            guard !line.isEmpty else { continue }
            let v = splitCSV(line)
            guard !v.isEmpty else { continue }
            // Non-timepoint stops may have no times at all. They used to be
            // dropped, which removed those stops from route lists and
            // schedules; they are now kept with empty times and filled by
            // `interpolateMissingStopTimes()` once the whole file is in.
            let rawDeparture = GTFSTime.normalized(field(v, csv.index, "departure_time"))
            let rawArrival   = GTFSTime.normalized(field(v, csv.index, "arrival_time"))
            let departure = rawDeparture.isEmpty ? rawArrival : rawDeparture
            let arrival   = rawArrival.isEmpty ? rawDeparture : rawArrival
            db.insertStopTime(
                tripId:    field(v, csv.index, "trip_id"),
                stopId:    field(v, csv.index, "stop_id"),
                arrival:   arrival,
                departure: departure,
                seq:       Int(field(v, csv.index, "stop_sequence")) ?? 0
            )
            count += 1
            if count % batchSize == 0 {
                try db.commit()
                try db.beginTransaction()
                if fileSize > 0 {
                    let approxBytes = Double(count) * 35.0
                    onProgress(min(approxBytes / Double(fileSize), 0.99))
                }
            }
        }
        db.finalizeStopTimeInsert()
        try db.commit()
        onProgress(1.0)
    }

    // MARK: - Helpers

    private func makeIndex(_ headers: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })
    }

    private func field(_ values: [String], _ idx: [String: Int], _ key: String) -> String {
        guard let i = idx[key], i < values.count else { return "" }
        return values[i]
    }

    /// Locates the directory containing the GTFS `.txt` files. Most feeds put
    /// them at the archive root; MobilityDatabase-rehosted archives often nest
    /// them one level deep (e.g. `extracted/gtfs_stm/stops.txt`). We probe for
    /// `stops.txt` at the root first, then scan first-level subdirectories.
    private static func findGtfsRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        let marker = "stops.txt"
        if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) {
            return dir
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if fm.fileExists(atPath: entry.appendingPathComponent(marker).path) {
                return entry
            }
        }
        return nil
    }

    /// Opens a CSV file, strips BOM from the header, and returns a reader + column index.
    /// Returns nil when the file doesn't exist or has no header row.
    private func openCSV(named name: String, in dir: URL) -> (reader: LineReader, index: [String: Int])? {
        let url = dir.appendingPathComponent(name)
        guard let reader = try? LineReader(url: url),
              var header = reader.nextLine() else { return nil }
        if header.hasPrefix("\u{FEFF}") { header = String(header.dropFirst()) }
        return (reader, makeIndex(splitCSV(header)))
    }

    /// Opens a CSV file and calls `insert` for every non-empty data row, wrapped in a single transaction.
    private func importCSVFile(
        named name: String,
        in dir: URL,
        to db: GTFSDatabase,
        insert: (_ values: [String], _ index: [String: Int]) throws -> Void
    ) throws {
        guard let csv = openCSV(named: name, in: dir) else { return }
        try db.beginTransaction()
        defer { try? db.commit() }
        while let line = csv.reader.nextLine() {
            guard !line.isEmpty else { continue }
            let v = splitCSV(line)
            guard !v.isEmpty else { continue }
            try insert(v, csv.index)
        }
    }
}
