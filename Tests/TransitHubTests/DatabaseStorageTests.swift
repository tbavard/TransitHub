import XCTest
@testable import TransitHub

final class DatabaseStorageTests: XCTestCase {

    func testSideFilesSitNextToTheDatabase() {
        let main = URL(fileURLWithPath: "/tmp/GTFS/gtfs_mdb-751.sqlite")
        XCTAssertEqual(GTFSDatabase.databaseFiles(for: main).map(\.lastPathComponent), [
            "gtfs_mdb-751.sqlite",
            "gtfs_mdb-751.sqlite-wal",
            "gtfs_mdb-751.sqlite-shm",
            "gtfs_mdb-751.sqlite-journal",
        ])
        XCTAssertTrue(GTFSDatabase.databaseFiles(for: main).allSatisfy {
            $0.deletingLastPathComponent().path == "/tmp/GTFS"
        })
    }

    func testDatabasesLiveOutsideDocumentsAndAreExcludedFromBackup() throws {
        let dir = GTFSDatabase.storageDirectory
        XCTAssertFalse(dir.path.contains("/Documents"))
        XCTAssertEqual(GTFSDatabase.forProviderId("x").databaseURL.deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL)
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
