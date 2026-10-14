import XCTest
@testable import TransitHub

final class StopRouteContextTests: XCTestCase {

    private let route24 = Route(gtfsId: "24", agencyId: "STM", shortName: "24", longName: "Sherbrooke",
                                type: 3, color: "009EE0", textColor: "FFFFFF", providerId: "stm")

    private lazy var schedule: [ScheduleEntry] = [
        entry("08:00:00", route: "24", short: "24", headsign: "Est",   dir: 0),
        entry("08:10:00", route: "24", short: "24", headsign: "Ouest", dir: 1),
        entry("08:05:00", route: "55", short: "55", headsign: "Nord",  dir: 0),
        entry("08:20:00", route: "24", short: "24", headsign: "Est",   dir: 0),
    ]

    // MARK: - filtered(for:)

    func testNoContextKeepsEverything() {
        XCTAssertEqual(schedule.filtered(for: nil).count, 4)
    }

    func testContextKeepsOnlyRouteAndDirection() {
        let ctx = StopRouteContext(route: route24, directionId: 0)
        let result = schedule.filtered(for: ctx)
        XCTAssertEqual(result.map(\.departureTime), ["08:00:00", "08:20:00"])
        XCTAssertTrue(result.allSatisfy { $0.routeId == "24" && $0.directionId == 0 })
    }

    func testUnknownDirectionFallsBackToWholeRoute() {
        // Feeds with inconsistent direction_id must not yield an empty screen.
        let ctx = StopRouteContext(route: route24, directionId: 7)
        let result = schedule.filtered(for: ctx)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.routeId == "24" })
    }

    // MARK: - groupedByRouteAndDirection()

    func testDirectionsAreSeparateGroups() {
        let groups = schedule.groupedByRouteAndDirection()
        XCTAssertEqual(groups.count, 3)   // 24 Est, 24 Ouest, 55 Nord
        let est = groups.first { $0.routeId == "24" && $0.headsign == "Est" }
        XCTAssertEqual(est?.entries.map(\.departureTime), ["08:00:00", "08:20:00"])
    }

    func testGroupsSortNaturallyByRouteNumber() {
        let mixed = [
            entry("08:00:00", route: "100", short: "100", headsign: "A", dir: 0),
            entry("08:00:00", route: "9",   short: "9",   headsign: "A", dir: 0),
            entry("08:00:00", route: "24",  short: "24",  headsign: "A", dir: 0),
        ]
        XCTAssertEqual(mixed.groupedByRouteAndDirection().map(\.routeShortName), ["9", "24", "100"])
    }

    func testGroupHeadsignIsMostFrequent() {
        let entries = [
            entry("08:00:00", route: "24", short: "24", headsign: "Terminus partiel", dir: 0),
            entry("08:10:00", route: "24", short: "24", headsign: "Est", dir: 0),
            entry("08:20:00", route: "24", short: "24", headsign: "Est", dir: 0),
        ]
        XCTAssertEqual(entries.groupedByRouteAndDirection().first?.headsign, "Est")
    }

    // MARK: - Helpers

    private func entry(_ time: String, route: String, short: String,
                       headsign: String, dir: Int) -> ScheduleEntry {
        ScheduleEntry(departureTime: time, tripId: "\(route)-\(time)", headsign: headsign,
                      routeId: route, routeShortName: short, routeColor: "009EE0",
                      directionId: dir)
    }
}
