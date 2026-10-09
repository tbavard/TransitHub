import XCTest
import SwiftUI
@testable import TransitHub

final class ScheduleEntryTests: XCTestCase {

    func testDisplayTimeStripsSeconds() {
        let e = makeEntry(time: "14:05:30")
        XCTAssertEqual(e.displayTime, "14:05")
    }

    func testDisplayTimeWrapsOvernightHours() {
        let e = makeEntry(time: "25:10:00")
        // 25h wraps to 01h for display.
        XCTAssertEqual(e.displayTime, "01:10")
    }

    func testIsNextDayDetectsOvernight() {
        XCTAssertTrue(makeEntry(time: "24:30:00").isNextDay)
        XCTAssertTrue(makeEntry(time: "25:05:00").isNextDay)
        XCTAssertFalse(makeEntry(time: "23:59:00").isNextDay)
    }

    // MARK: - Helpers

    private func makeEntry(time: String) -> ScheduleEntry {
        ScheduleEntry(
            departureTime: time,
            tripId: "t1",
            headsign: "Nord",
            routeId: "r",
            routeShortName: "55",
            routeColor: "009EE0"
        )
    }
}

final class RouteColorTests: XCTestCase {

    func testMetroLineGetsOfficialColor() {
        // Metro line 1 (Verte) — officialRouteColor should override the feed color.
        let r = Route(gtfsId: "1", agencyId: "STM", shortName: "1", longName: "Verte",
                      type: 1, color: "000000", textColor: "FFFFFF", providerId: "stm")
        XCTAssertEqual(r.officialRouteColor, Color(hex: "EF7D00"))
    }

    func testNonStmRoutesAlwaysUseFeedColor() {
        // Non-STM lines must fall through to the GTFS feed color regardless
        // of shortName collisions with the STM metro color table.
        let r = Route(gtfsId: "1", agencyId: "RTL", shortName: "1", longName: "foo",
                      type: 3, color: "ABCDEF", textColor: "FFFFFF", providerId: "rtl")
        XCTAssertEqual(r.officialRouteColor, Color(hex: "ABCDEF"))
    }
}
