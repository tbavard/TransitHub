import Foundation
import SQLite3

// MARK: - Error

enum GTFSError: LocalizedError {
    case databaseError(String)
    case downloadError(String)
    case parseError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .databaseError(let m): return "DB: \(m)"
        case .downloadError(let m): return "Download: \(m)"
        case .parseError(let m):    return "Parse: \(m)"
        case .networkError(let e):  return "Network: \(e.localizedDescription)"
        }
    }
}

// MARK: - GTFSDatabase

final class GTFSDatabase {

    // MARK: Factory
    //
    // Each call returns a *new* instance with its own SQLite connection pointer.
    // Reusing a single instance across concurrent Task.detached calls caused
    // races on the `db` OpaquePointer (one task's close() would nil it while
    // another was still querying). SQLite WAL mode supports concurrent readers
    // so independent connections to the same file are safe.

    static func forProvider(_ provider: TransitProvider) -> GTFSDatabase {
        GTFSDatabase(providerId: provider.id)
    }

    static func forProviderId(_ id: String) -> GTFSDatabase {
        GTFSDatabase(providerId: id)
    }

    /// Bump when the import format changes in a way that requires existing
    /// databases to be rebuilt (checked by `GTFSService.isDatabaseFresh`).
    /// v2: stop_times times normalized to zero-padded "HH:MM:SS".
    /// v3: non-timepoint stop_times kept and interpolated instead of dropped.
    static let dataVersion = 3

    // MARK: State

    let providerId: String
    private var db: OpaquePointer?

    init(providerId: String) {
        self.providerId = providerId
    }

    var databaseURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gtfs_\(providerId).sqlite")
    }

    var exists: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    // MARK: Lifecycle

    func open() throws {
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw GTFSError.databaseError("Cannot open: \(String(cString: sqlite3_errmsg(db)))")
        }
        try rawExec("PRAGMA journal_mode = WAL")
        try rawExec("PRAGMA synchronous = NORMAL")
        try rawExec("PRAGMA cache_size = -8000")  // 8 MB page cache
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    func deleteDatabase() throws {
        if exists { try FileManager.default.removeItem(at: databaseURL) }
    }

    // MARK: Schema

    func createSchema() throws {
        try rawExec("""
            CREATE TABLE IF NOT EXISTS routes (
                route_id       TEXT PRIMARY KEY,
                agency_id      TEXT,
                route_short_name TEXT,
                route_long_name  TEXT,
                route_type     INTEGER,
                route_color    TEXT,
                route_text_color TEXT
            );
            CREATE TABLE IF NOT EXISTS stops (
                stop_id        TEXT PRIMARY KEY,
                stop_name      TEXT,
                stop_lat       REAL,
                stop_lon       REAL,
                location_type  INTEGER DEFAULT 0,
                parent_station TEXT
            );
            CREATE TABLE IF NOT EXISTS trips (
                trip_id        TEXT PRIMARY KEY,
                route_id       TEXT,
                service_id     TEXT,
                trip_headsign  TEXT,
                direction_id   INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_trips_route   ON trips(route_id);
            CREATE INDEX IF NOT EXISTS idx_trips_service ON trips(service_id);
            CREATE TABLE IF NOT EXISTS stop_times (
                trip_id        TEXT,
                stop_id        TEXT,
                arrival_time   TEXT,
                departure_time TEXT,
                stop_sequence  INTEGER,
                PRIMARY KEY (trip_id, stop_sequence)
            );
            CREATE INDEX IF NOT EXISTS idx_st_stop ON stop_times(stop_id);
            CREATE TABLE IF NOT EXISTS calendar (
                service_id TEXT PRIMARY KEY,
                monday     INTEGER, tuesday   INTEGER, wednesday INTEGER,
                thursday   INTEGER, friday    INTEGER, saturday  INTEGER, sunday INTEGER,
                start_date TEXT, end_date TEXT
            );
            CREATE TABLE IF NOT EXISTS calendar_dates (
                service_id     TEXT,
                date           TEXT,
                exception_type INTEGER,
                PRIMARY KEY (service_id, date)
            );
            CREATE TABLE IF NOT EXISTS metadata (
                key   TEXT PRIMARY KEY,
                value TEXT
            );
        """)
    }

    // MARK: - Queries

    func fetchRoutes() throws -> [Route] {
        var result: [Route] = []
        let pid = providerId
        try query(
            "SELECT route_id, COALESCE(agency_id,''), route_short_name, route_long_name, route_type, COALESCE(route_color,''), COALESCE(route_text_color,'') FROM routes ORDER BY route_type, CAST(route_short_name AS INTEGER), route_short_name"
        ) { stmt in
            result.append(Route(
                gtfsId:      col(stmt, 0),
                agencyId:    col(stmt, 1),
                shortName:   col(stmt, 2),
                longName:    col(stmt, 3),
                type:        Int(sqlite3_column_int(stmt, 4)),
                color:       col(stmt, 5),
                textColor:   col(stmt, 6),
                providerId:  pid
            ))
        }
        return result
    }

    func fetchStops() throws -> [Stop] {
        var result: [Stop] = []
        let pid = providerId
        try query(
            "SELECT stop_id, stop_name, stop_lat, stop_lon, COALESCE(location_type,0), COALESCE(parent_station,'') FROM stops WHERE COALESCE(location_type,0) = 0"
        ) { stmt in
            let parentStr = col(stmt, 5)
            result.append(Stop(
                id:            col(stmt, 0),
                name:          col(stmt, 1),
                lat:           sqlite3_column_double(stmt, 2),
                lon:           sqlite3_column_double(stmt, 3),
                locationType:  Int(sqlite3_column_int(stmt, 4)),
                parentStation: parentStr.isEmpty ? nil : parentStr,
                providerId:    pid
            ))
        }
        return result
    }

    /// Returns the representative headsign for each direction of a route, e.g. ["Angrignon", "Honoré-Beaugrand"]
    func fetchDirectionHeadsigns(routeId: String) throws -> [Int: String] {
        // Pick the most frequent headsign per direction so we get the "main" destination
        let sql = """
            SELECT direction_id, trip_headsign, COUNT(*) AS cnt
            FROM trips
            WHERE route_id = ?
            GROUP BY direction_id, trip_headsign
            ORDER BY direction_id, cnt DESC
        """
        var best: [Int: (String, Int)] = [:]   // direction -> (headsign, count)
        try query(sql, [routeId]) { stmt in
            let dir   = Int(sqlite3_column_int(stmt, 0))
            let sign  = col(stmt, 1)
            let count = Int(sqlite3_column_int(stmt, 2))
            if let existing = best[dir] {
                if count > existing.1 { best[dir] = (sign, count) }
            } else {
                best[dir] = (sign, count)
            }
        }
        return best.mapValues { $0.0 }
    }

    func fetchStopsForRoute(_ routeId: String, direction: Int) throws -> [Stop] {
        // 1. Ordered stop list of every trip, deduplicated into distinct
        //    patterns (variants: branches, short turns…). Sorting by
        //    MIN(stop_sequence) across trips scrambled the order as soon as
        //    variants numbered their stops differently.
        var stopsByTrip: [String: [String]] = [:]
        try query("""
            SELECT st.trip_id, st.stop_id
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            WHERE t.route_id = ? AND t.direction_id = ?
            ORDER BY st.trip_id, st.stop_sequence
        """, [routeId, direction]) { stmt in
            stopsByTrip[col(stmt, 0), default: []].append(col(stmt, 1))
        }
        let order = Self.mergedStopOrder(Array(Set(stopsByTrip.values)))

        // 2. Stop details, then laid out in the merged order.
        var byId: [String: Stop] = [:]
        let pid = providerId
        try query("""
            SELECT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon,
                   COALESCE(s.location_type,0), COALESCE(s.parent_station,'')
            FROM stops s
            WHERE s.stop_id IN (
                SELECT st.stop_id FROM stop_times st
                JOIN trips t ON st.trip_id = t.trip_id
                WHERE t.route_id = ? AND t.direction_id = ?
            )
        """, [routeId, direction]) { stmt in
            let ps = col(stmt, 5)
            let stop = Stop(
                id:            col(stmt, 0),
                name:          col(stmt, 1),
                lat:           sqlite3_column_double(stmt, 2),
                lon:           sqlite3_column_double(stmt, 3),
                locationType:  Int(sqlite3_column_int(stmt, 4)),
                parentStation: ps.isEmpty ? nil : ps,
                providerId:    pid
            )
            byId[stop.id] = stop
        }
        return order.compactMap { byId[$0] }
    }

    /// Merges the stop patterns of a route's variants into one display order.
    /// The longest pattern is the backbone; stops from other variants are
    /// inserted next to the backbone stop they follow (or, for a branch that
    /// starts elsewhere, just before the first stop it shares).
    static func mergedStopOrder(_ patterns: [[String]]) -> [String] {
        var order: [String] = []
        let longestFirst = patterns.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1)
        }
        for pattern in longestFirst {
            var cursor: Int? = nil       // insertion point after the last placed stop
            var leading: [String] = []   // new stops seen before any known stop
            for stop in pattern {
                if let i = order.firstIndex(of: stop) {
                    if leading.isEmpty {
                        cursor = i + 1
                    } else {
                        order.insert(contentsOf: leading, at: i)
                        cursor = i + leading.count + 1
                        leading = []
                    }
                } else if let c = cursor {
                    order.insert(stop, at: c)
                    cursor = c + 1
                } else if !leading.contains(stop) {
                    leading.append(stop)
                }
            }
            // Pattern shares no stop with what's already placed.
            order.append(contentsOf: leading)
        }
        return order
    }

    func fetchScheduledDepartures(for tripIds: [String]) throws -> [String: [Int: String]] {
        guard !tripIds.isEmpty else { return [:] }
        var result: [String: [Int: String]] = [:]
        var offset = 0
        while offset < tripIds.count {
            let chunk = Array(tripIds[offset..<min(offset + 500, tripIds.count)])
            let ph = chunk.map { _ in "?" }.joined(separator: ",")
            try query(
                "SELECT trip_id, stop_sequence, departure_time FROM stop_times WHERE trip_id IN (\(ph))",
                chunk
            ) { stmt in
                let tripId  = col(stmt, 0)
                let seq     = Int(sqlite3_column_int(stmt, 1))
                let depTime = col(stmt, 2)
                if result[tripId] == nil { result[tripId] = [:] }
                result[tripId]![seq] = depTime
            }
            offset += 500
        }
        return result
    }

    /// Departures at a stop for the current service window: today's services,
    /// plus yesterday's after-midnight trips (GTFS times ≥ 24:00) re-expressed
    /// on today's clock ("25:10:00" → "01:10:00"). Sorted by departure time.
    func fetchSchedule(stopId: String, services: ActiveServices) throws -> [ScheduleEntry] {
        let today = try fetchDepartures(stopId: stopId, serviceIds: services.today,
                                        fromPreviousServiceDay: false)
        let overnight = try fetchDepartures(stopId: stopId, serviceIds: services.yesterday,
                                            fromPreviousServiceDay: true)
        return (overnight + today).sorted { $0.departureTime < $1.departureTime }
    }

    private func fetchDepartures(stopId: String, serviceIds: [String],
                                 fromPreviousServiceDay: Bool) throws -> [ScheduleEntry] {
        guard !serviceIds.isEmpty else { return [] }
        let ph = serviceIds.map { _ in "?" }.joined(separator: ",")
        // The EXISTS clause drops the trip's last stop: at a terminus the
        // vehicle only arrives, nobody can board. It's a primary-key lookup
        // on (trip_id, stop_sequence), so it stays cheap.
        let sql = """
            SELECT st.departure_time, st.trip_id, t.trip_headsign,
                   t.route_id, r.route_short_name, COALESCE(r.route_color,''),
                   COALESCE(t.direction_id, 0), st.stop_sequence
            FROM stop_times st
            JOIN trips  t ON st.trip_id  = t.trip_id
            JOIN routes r ON t.route_id  = r.route_id
            WHERE st.stop_id = ? AND t.service_id IN (\(ph))
              AND st.departure_time >= ?
              AND EXISTS (SELECT 1 FROM stop_times nx
                          WHERE nx.trip_id = st.trip_id
                            AND nx.stop_sequence > st.stop_sequence)
            ORDER BY st.departure_time
        """
        var params: [Any] = [stopId]
        params.append(contentsOf: serviceIds)
        // "00:00:00" lower bound also excludes rows left without a time.
        params.append(fromPreviousServiceDay ? "24:00:00" : "00:00:00")
        var result: [ScheduleEntry] = []
        try query(sql, params) { stmt in
            let raw = col(stmt, 0)
            let time = fromPreviousServiceDay ? (GTFSTime.shiftedFromPreviousDay(raw) ?? raw) : raw
            result.append(ScheduleEntry(
                departureTime:  time,
                tripId:         col(stmt, 1),
                headsign:       col(stmt, 2),
                routeId:        col(stmt, 3),
                routeShortName: col(stmt, 4),
                routeColor:     col(stmt, 5),
                directionId:    Int(sqlite3_column_int(stmt, 6)),
                stopSequence:   Int(sqlite3_column_int(stmt, 7))
            ))
        }
        return result
    }

    // MARK: - Trip planning

    /// A single direct trip between two stops on the same vehicle (no transfer).
    struct DirectTripRow {
        let tripId: String
        let routeId: String
        let routeShortName: String
        let routeLongName: String
        let routeColor: String
        let headsign: String
        let fromStopId: String
        let toStopId: String
        let departureTime: String   // at from_stop
        let arrivalTime: String     // at to_stop
        let stopCount: Int          // inclusive of both ends
        let fromSequence: Int
        let toSequence: Int
    }

    /// Finds trips that visit one of `fromStopIds` and later (higher stop_sequence)
    /// one of `toStopIds` on the same vehicle, restricted to today's services
    /// and departures at or after `afterTime` (GTFS "HH:MM:SS" — may exceed 24h).
    /// Sorted by earliest departure, cut at `limit` rows.
    func fetchDirectTrips(
        fromStopIds: [String],
        toStopIds:   [String],
        serviceIds:  [String],
        afterTime:   String,
        limit:       Int = 20
    ) throws -> [DirectTripRow] {
        guard !fromStopIds.isEmpty, !toStopIds.isEmpty, !serviceIds.isEmpty else { return [] }

        let fromPh = fromStopIds.map { _ in "?" }.joined(separator: ",")
        let toPh   = toStopIds  .map { _ in "?" }.joined(separator: ",")
        let svcPh  = serviceIds .map { _ in "?" }.joined(separator: ",")

        let sql = """
            SELECT t.trip_id, t.route_id,
                   r.route_short_name, r.route_long_name, COALESCE(r.route_color,''),
                   t.trip_headsign,
                   st1.stop_id, st2.stop_id,
                   st1.departure_time, st2.arrival_time,
                   (st2.stop_sequence - st1.stop_sequence + 1) AS stops_between,
                   st1.stop_sequence, st2.stop_sequence
            FROM stop_times st1
            JOIN stop_times st2 ON st2.trip_id = st1.trip_id
                                 AND st2.stop_sequence > st1.stop_sequence
            JOIN trips  t ON t.trip_id = st1.trip_id
            JOIN routes r ON r.route_id = t.route_id
            WHERE st1.stop_id IN (\(fromPh))
              AND st2.stop_id IN (\(toPh))
              AND t.service_id IN (\(svcPh))
              AND st1.departure_time >= ?
              AND st2.arrival_time <> ''
            ORDER BY st1.departure_time ASC, stops_between ASC
            LIMIT ?
        """

        var params: [Any] = []
        params.append(contentsOf: fromStopIds)
        params.append(contentsOf: toStopIds)
        params.append(contentsOf: serviceIds)
        params.append(afterTime)
        params.append(limit)

        var result: [DirectTripRow] = []
        try query(sql, params) { stmt in
            result.append(DirectTripRow(
                tripId:         col(stmt, 0),
                routeId:        col(stmt, 1),
                routeShortName: col(stmt, 2),
                routeLongName:  col(stmt, 3),
                routeColor:     col(stmt, 4),
                headsign:       col(stmt, 5),
                fromStopId:     col(stmt, 6),
                toStopId:       col(stmt, 7),
                departureTime:  col(stmt, 8),
                arrivalTime:    col(stmt, 9),
                stopCount:      Int(sqlite3_column_int(stmt, 10)),
                fromSequence:   Int(sqlite3_column_int(stmt, 11)),
                toSequence:     Int(sqlite3_column_int(stmt, 12))
            ))
        }
        return result
    }

    /// Today's and yesterday's active services — see `ActiveServices`.
    func fetchActiveServices(for date: Date = .init()) throws -> ActiveServices {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        return ActiveServices(
            today:     try fetchActiveServiceIds(for: date),
            yesterday: try fetchActiveServiceIds(for: yesterday)
        )
    }

    func fetchActiveServiceIds(for date: Date = .init()) throws -> [String] {
        let cal = Calendar.current
        let dayColumns = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]
        let weekday = cal.component(.weekday, from: date) - 1  // 0=Sun
        let dayCol  = dayColumns[weekday]

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        let dateStr = fmt.string(from: date)

        var ids: Set<String> = []
        try query(
            "SELECT service_id FROM calendar WHERE \(dayCol) = 1 AND start_date <= ? AND end_date >= ?",
            [dateStr, dateStr]
        ) { stmt in ids.insert(col(stmt, 0)) }

        var removed = Set<String>()
        var added   = Set<String>()
        try query("SELECT service_id, exception_type FROM calendar_dates WHERE date = ?", [dateStr]) { stmt in
            let sid = col(stmt, 0)
            let typ = Int(sqlite3_column_int(stmt, 1))
            if typ == 1 { added.insert(sid) }
            if typ == 2 { removed.insert(sid) }
        }
        return ids.subtracting(removed).union(added).sorted()
    }

    func countRows(in table: String) throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM \(table)") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Earliest service date of this feed (YYYYMMDD): MIN start_date in
    /// `calendar` and MIN added date in `calendar_dates`. Agencies often
    /// publish the next service period before it starts (e.g. RTL), so this
    /// can lie in the future. Read on demand — no re-import needed.
    func fetchFeedStartDate() throws -> String? {
        var calStart: String?
        var cdStart:  String?
        try query("SELECT MIN(start_date) FROM calendar") { stmt in
            let v = col(stmt, 0); if !v.isEmpty { calStart = v }
        }
        try query("SELECT MIN(date) FROM calendar_dates WHERE exception_type = 1") { stmt in
            let v = col(stmt, 0); if !v.isEmpty { cdStart = v }
        }
        return [calStart, cdStart].compactMap { $0 }.min()
    }

    /// Returns the latest service date covered by this feed (YYYYMMDD), derived
    /// from the maximum end_date in `calendar` and the maximum date in
    /// `calendar_dates`. Returns nil if both tables are empty.
    func fetchFeedEndDate() throws -> String? {
        var calEnd: String?
        var cdEnd:  String?
        try query("SELECT MAX(end_date) FROM calendar") { stmt in
            let v = col(stmt, 0); if !v.isEmpty { calEnd = v }
        }
        try query("SELECT MAX(date) FROM calendar_dates") { stmt in
            let v = col(stmt, 0); if !v.isEmpty { cdEnd = v }
        }
        return [calEnd, cdEnd].compactMap { $0 }.max()
    }

    func getMetadata(_ key: String) throws -> String? {
        var value: String?
        try query("SELECT value FROM metadata WHERE key = ?", [key]) { stmt in
            value = col(stmt, 0)
        }
        return value
    }

    func setMetadata(_ key: String, _ value: String) throws {
        try execute("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)", [key, value])
    }

    // MARK: - Batch Insert (reusable prepared statements)

    func beginTransaction() throws { try rawExec("BEGIN TRANSACTION") }
    func commit()           throws { try rawExec("COMMIT") }
    func rollback()                { try? rawExec("ROLLBACK") }

    func insertRoute(_ r: Route) throws {
        try execute("INSERT OR REPLACE INTO routes VALUES (?,?,?,?,?,?,?)",
                    [r.gtfsId, r.agencyId, r.shortName, r.longName, r.type, r.color, r.textColor])
    }

    func insertStop(_ s: Stop) throws {
        try execute("INSERT OR REPLACE INTO stops VALUES (?,?,?,?,?,?)",
                    [s.id, s.name, s.lat, s.lon, s.locationType, s.parentStation ?? ""])
    }

    func insertTrip(id: String, routeId: String, serviceId: String, headsign: String, directionId: Int) throws {
        try execute("INSERT OR REPLACE INTO trips VALUES (?,?,?,?,?)",
                    [id, routeId, serviceId, headsign, directionId])
    }

    func insertCalendar(_ c: ServiceCalendar) throws {
        try execute("INSERT OR REPLACE INTO calendar VALUES (?,?,?,?,?,?,?,?,?,?)", [
            c.serviceId,
            c.monday ? 1 : 0, c.tuesday ? 1 : 0, c.wednesday ? 1 : 0,
            c.thursday ? 1 : 0, c.friday ? 1 : 0, c.saturday ? 1 : 0, c.sunday ? 1 : 0,
            c.startDate, c.endDate
        ])
    }

    func insertCalendarException(serviceId: String, date: String, type: Int) throws {
        try execute("INSERT OR REPLACE INTO calendar_dates VALUES (?,?,?)", [serviceId, date, type])
    }

    // Batch stop_time insert using a persistent prepared statement for performance
    private var stopTimeStmt: OpaquePointer?

    func prepareStopTimeInsert() throws {
        let sql = "INSERT OR IGNORE INTO stop_times VALUES (?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stopTimeStmt, nil) == SQLITE_OK else {
            throw GTFSError.databaseError("Prepare stop_time insert: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func insertStopTime(tripId: String, stopId: String, arrival: String, departure: String, seq: Int) {
        let stmt = stopTimeStmt
        sqlite3_bind_text(stmt, 1, tripId,    -1, GTFSDatabase.transient)
        sqlite3_bind_text(stmt, 2, stopId,    -1, GTFSDatabase.transient)
        sqlite3_bind_text(stmt, 3, arrival,   -1, GTFSDatabase.transient)
        sqlite3_bind_text(stmt, 4, departure, -1, GTFSDatabase.transient)
        sqlite3_bind_int64(stmt, 5, Int64(seq))
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func finalizeStopTimeInsert() {
        sqlite3_finalize(stopTimeStmt)
        stopTimeStmt = nil
    }

    /// Fills stop_times rows imported without times (non-timepoint stops) by
    /// linear interpolation between the surrounding timed stops of the same
    /// trip. Works in chunks of trips to keep memory bounded on large feeds.
    func interpolateMissingStopTimes() throws {
        var tripIds: [String] = []
        try query("SELECT DISTINCT trip_id FROM stop_times WHERE departure_time = ''") { stmt in
            tripIds.append(col(stmt, 0))
        }
        guard !tripIds.isEmpty else { return }

        var update: OpaquePointer?
        let sql = "UPDATE stop_times SET arrival_time = ?, departure_time = ? WHERE trip_id = ? AND stop_sequence = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &update, nil) == SQLITE_OK else {
            throw GTFSError.databaseError("Prepare interpolation: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(update) }

        try beginTransaction()
        do {
            for start in stride(from: 0, to: tripIds.count, by: 500) {
                let chunk = Array(tripIds[start..<min(start + 500, tripIds.count)])
                let ph = chunk.map { _ in "?" }.joined(separator: ",")
                var rowsByTrip: [String: [(seq: Int, time: String)]] = [:]
                try query(
                    "SELECT trip_id, stop_sequence, departure_time FROM stop_times WHERE trip_id IN (\(ph)) ORDER BY trip_id, stop_sequence",
                    chunk
                ) { stmt in
                    rowsByTrip[col(stmt, 0), default: []].append(
                        (seq: Int(sqlite3_column_int(stmt, 1)), time: col(stmt, 2))
                    )
                }
                for (tripId, rows) in rowsByTrip {
                    let filled = GTFSTime.interpolated(rows.map { $0.time.isEmpty ? nil : $0.time })
                    for (row, value) in zip(rows, filled) where row.time.isEmpty {
                        guard let value else { continue }   // no anchor on one side
                        sqlite3_bind_text(update, 1, value,  -1, GTFSDatabase.transient)
                        sqlite3_bind_text(update, 2, value,  -1, GTFSDatabase.transient)
                        sqlite3_bind_text(update, 3, tripId, -1, GTFSDatabase.transient)
                        sqlite3_bind_int64(update, 4, Int64(row.seq))
                        sqlite3_step(update)
                        sqlite3_reset(update)
                        sqlite3_clear_bindings(update)
                    }
                }
            }
            try commit()
        } catch {
            rollback()
            throw error
        }
    }

    // MARK: - Internal helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func rawExec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? "Unknown"
            sqlite3_free(errmsg)
            throw GTFSError.databaseError(msg)
        }
    }

    private func execute(_ sql: String, _ params: [Any]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSError.databaseError("Prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw GTFSError.databaseError("Step (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func query(_ sql: String, _ params: [Any] = [], _ handler: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSError.databaseError("Prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        while sqlite3_step(stmt) == SQLITE_ROW { handler(stmt) }
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [Any]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let s as String:  sqlite3_bind_text(stmt, idx, s, -1, GTFSDatabase.transient)
            case let n as Int:     sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double:  sqlite3_bind_double(stmt, idx, d)
            default:               sqlite3_bind_text(stmt, idx, "\(p)", -1, GTFSDatabase.transient)
            }
        }
    }

    private func col(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: ptr)
    }
}
