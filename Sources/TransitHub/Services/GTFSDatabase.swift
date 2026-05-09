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
        var result: [Stop] = []
        let pid = providerId
        // Use MIN(stop_sequence) to get a stable ordering across trips for the same route/direction
        let sql = """
            SELECT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon,
                   COALESCE(s.location_type,0), COALESCE(s.parent_station,''),
                   MIN(st.stop_sequence) AS min_seq
            FROM stops s
            JOIN stop_times st ON s.stop_id  = st.stop_id
            JOIN trips       t  ON st.trip_id = t.trip_id
            WHERE t.route_id = ? AND t.direction_id = ?
            GROUP BY s.stop_id
            ORDER BY min_seq
        """
        try query(sql, [routeId, direction]) { stmt in
            let ps = col(stmt, 5)
            result.append(Stop(
                id:            col(stmt, 0),
                name:          col(stmt, 1),
                lat:           sqlite3_column_double(stmt, 2),
                lon:           sqlite3_column_double(stmt, 3),
                locationType:  Int(sqlite3_column_int(stmt, 4)),
                parentStation: ps.isEmpty ? nil : ps,
                providerId:    pid
            ))
        }
        return result
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

    func fetchSchedule(stopId: String, serviceIds: [String]) throws -> [ScheduleEntry] {
        guard !serviceIds.isEmpty else { return [] }
        let ph = serviceIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT st.departure_time, st.trip_id, t.trip_headsign,
                   t.route_id, r.route_short_name, COALESCE(r.route_color,'')
            FROM stop_times st
            JOIN trips  t ON st.trip_id  = t.trip_id
            JOIN routes r ON t.route_id  = r.route_id
            WHERE st.stop_id = ? AND t.service_id IN (\(ph))
            ORDER BY st.departure_time
        """
        var params: [Any] = [stopId]
        params.append(contentsOf: serviceIds)
        var result: [ScheduleEntry] = []
        try query(sql, params) { stmt in
            result.append(ScheduleEntry(
                departureTime:  col(stmt, 0),
                tripId:         col(stmt, 1),
                headsign:       col(stmt, 2),
                routeId:        col(stmt, 3),
                routeShortName: col(stmt, 4),
                routeColor:     col(stmt, 5)
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
                   (st2.stop_sequence - st1.stop_sequence + 1) AS stops_between
            FROM stop_times st1
            JOIN stop_times st2 ON st2.trip_id = st1.trip_id
                                 AND st2.stop_sequence > st1.stop_sequence
            JOIN trips  t ON t.trip_id = st1.trip_id
            JOIN routes r ON r.route_id = t.route_id
            WHERE st1.stop_id IN (\(fromPh))
              AND st2.stop_id IN (\(toPh))
              AND t.service_id IN (\(svcPh))
              AND st1.departure_time >= ?
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
                stopCount:      Int(sqlite3_column_int(stmt, 10))
            ))
        }
        return result
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
