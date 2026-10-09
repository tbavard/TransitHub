import XCTest
@testable import TransitHub

final class RecentRoutesTests: XCTestCase {

    func testAddingPutsRouteFirst() {
        XCTAssertEqual(RecentRoutes.ids(from: RecentRoutes.adding("stm:24", to: "stm:55")), ["stm:24", "stm:55"])
    }

    func testAddingExistingRouteMovesItWithoutDuplicate() {
        let raw = RecentRoutes.adding("stm:55", to: "stm:24\nstm:55\nstm:80")
        XCTAssertEqual(RecentRoutes.ids(from: raw), ["stm:55", "stm:24", "stm:80"])
    }

    func testAddingRespectsLimit() {
        let raw = RecentRoutes.adding("e", to: "a\nb\nc", limit: 3)
        XCTAssertEqual(RecentRoutes.ids(from: raw), ["e", "a", "b"])
    }

    func testEmptyStorage() {
        XCTAssertEqual(RecentRoutes.ids(from: ""), [])
    }
}
