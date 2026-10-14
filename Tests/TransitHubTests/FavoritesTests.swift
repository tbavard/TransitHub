import XCTest
@testable import TransitHub

final class FavoritesMigrationTests: XCTestCase {

    func testBareIdsAreNamespacedToStm() {
        let input: Set<String> = ["51425", "52001"]
        let out = AppViewModel.migrateLegacyFavoriteKeys(input)
        XCTAssertEqual(out, ["stm:51425", "stm:52001"])
    }

    func testAlreadyNamespacedKeysPassThrough() {
        let input: Set<String> = ["stm:51425", "mdb-9999:B12"]
        let out = AppViewModel.migrateLegacyFavoriteKeys(input)
        XCTAssertEqual(out, input)
    }

    func testMixedInputIsMigratedInPlace() {
        let input: Set<String> = ["51425", "mdb-9999:B12"]
        let out = AppViewModel.migrateLegacyFavoriteKeys(input)
        XCTAssertEqual(out, ["stm:51425", "mdb-9999:B12"])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(AppViewModel.migrateLegacyFavoriteKeys([]).isEmpty)
    }
}

final class StopFavoriteKeyTests: XCTestCase {

    func testFavoriteKeyFormat() {
        let s = Stop(id: "51425", name: "De la Commune / Place Jacques-Cartier",
                     lat: 0, lon: 0, locationType: 0, parentStation: nil, providerId: "stm")
        XCTAssertEqual(s.favoriteKey, "stm:51425")
    }

    func testStopsFromDifferentProvidersAreNotEqualDespiteSharedId() {
        let a = Stop(id: "100", name: "X", lat: 0, lon: 0,
                     locationType: 0, parentStation: nil, providerId: "stm")
        let b = Stop(id: "100", name: "Y", lat: 0, lon: 0,
                     locationType: 0, parentStation: nil, providerId: "rtl")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.hashValue, b.hashValue)
    }

    func testStopsFromSameProviderWithSameIdAreEqual() {
        let a = Stop(id: "100", name: "X", lat: 0, lon: 0,
                     locationType: 0, parentStation: nil, providerId: "stm")
        let b = Stop(id: "100", name: "X", lat: 45, lon: -73,
                     locationType: 0, parentStation: "P1", providerId: "stm")
        // Equality is id+providerId only — metadata differences don't matter.
        XCTAssertEqual(a, b)
    }
}
