import XCTest
@testable import TransitHub

final class FavoritesEngineTests: XCTestCase {

    // MARK: - Migration (behavior previously covered via AppViewModel alias)

    func testMigrateNamespacesBareIds() {
        XCTAssertEqual(FavoritesEngine.migrateLegacyKeys(["51425"]), ["stm:51425"])
    }

    func testMigrateLeavesNamespacedKeysUntouched() {
        let input: Set<String> = ["stm:51425", "mdb-9999:B12"]
        XCTAssertEqual(FavoritesEngine.migrateLegacyKeys(input), input)
    }

    // MARK: - Toggling

    func testTogglingAddsMissingKey() {
        XCTAssertEqual(FavoritesEngine.toggling("stm:1", in: []), ["stm:1"])
    }

    func testTogglingRemovesPresentKey() {
        XCTAssertEqual(FavoritesEngine.toggling("stm:1", in: ["stm:1", "stm:2"]), ["stm:2"])
    }

    // MARK: - Merge (union, then migrate — never loses offline additions)

    func testMergeUnionsLocalAndRemote() {
        let merged = FavoritesEngine.merge(local: ["stm:1"], remote: ["stm:2"])
        XCTAssertEqual(merged, ["stm:1", "stm:2"])
    }

    func testMergeMigratesLegacyRemoteEntries() {
        let merged = FavoritesEngine.merge(local: ["stm:1"], remote: ["999"])
        XCTAssertEqual(merged, ["stm:1", "stm:999"])
    }

    // MARK: - Load (combines both sources)

    func testLoadedPrefersUnionOfRemoteAndLocal() {
        let out = FavoritesEngine.loaded(remote: ["mdb-2:B12"], local: ["stm:1"])
        XCTAssertEqual(out, ["mdb-2:B12", "stm:1"])
    }

    func testLoadedHandlesNilRemote() {
        let out = FavoritesEngine.loaded(remote: nil, local: ["stm:1"])
        XCTAssertEqual(out, ["stm:1"])
    }
}
