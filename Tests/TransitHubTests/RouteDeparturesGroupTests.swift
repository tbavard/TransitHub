import XCTest
@testable import TransitHub

/// `groupedByRouteAndHeadsign` feeds the departure cards (one card per line +
/// direction, one swipe page per upcoming departure).
final class RouteDeparturesGroupTests: XCTestCase {

    /// A departure `minutes` from now, as a GTFS time string.
    private func entry(
        route: String, headsign: String, inMinutes minutes: Int,
        realtime: RealtimeStatus? = nil
    ) -> ScheduleEntry {
        let time = TripPlanner.gtfsTimeString(from: Date().addingTimeInterval(Double(minutes) * 60))
        return ScheduleEntry(
            departureTime: time, tripId: "t-\(route)-\(minutes)", headsign: headsign,
            routeId: route, routeShortName: route, routeColor: "FF0000",
            directionId: 0, stopSequence: 1, realtime: realtime)
    }

    /// Departures near midnight wrap to the next day and would look "already
    /// departed"; these tests only make sense during the day.
    private func skipNearMidnight() throws {
        let hour = Calendar.current.component(.hour, from: Date())
        try XCTSkipIf(hour >= 23 || hour < 1, "Time-of-day dependent test")
    }

    func testGroupsByRouteAndHeadsignAndKeepsTheNextDepartures() throws {
        try skipNearMidnight()
        let entries = [
            entry(route: "55", headsign: "Nord", inMinutes: 5),
            entry(route: "55", headsign: "Nord", inMinutes: 12),
            entry(route: "55", headsign: "Nord", inMinutes: 20),
            entry(route: "55", headsign: "Sud",  inMinutes: 8),
        ]

        let groups = entries.groupedByRouteAndHeadsign(limit: 2)

        XCTAssertEqual(groups.count, 2, "one group per line + direction")
        let nord = try XCTUnwrap(groups.first { $0.headsign == "Nord" })
        XCTAssertEqual(nord.minutes.count, 2, "only the next `limit` departures are kept")
        XCTAssertEqual(nord.minutes, nord.minutes.sorted())
    }

    func testGroupsAreOrderedBySoonestDeparture() throws {
        try skipNearMidnight()
        let entries = [
            entry(route: "10", headsign: "Est",   inMinutes: 15),
            entry(route: "55", headsign: "Nord",  inMinutes: 4),
        ]

        let groups = entries.groupedByRouteAndHeadsign()

        XCTAssertEqual(groups.map(\.routeShortName), ["55", "10"])
    }

    func testCanceledDeparturesAreLeftOut() throws {
        try skipNearMidnight()
        let entries = [
            entry(route: "55", headsign: "Nord", inMinutes: 5, realtime: .canceled),
            entry(route: "55", headsign: "Nord", inMinutes: 12),
        ]

        let groups = entries.groupedByRouteAndHeadsign()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.minutes.count, 1)
    }

    func testAGroupWithOnlyCanceledDeparturesDisappears() throws {
        try skipNearMidnight()
        let entries = [entry(route: "55", headsign: "Nord", inMinutes: 5, realtime: .canceled)]

        XCTAssertTrue(entries.groupedByRouteAndHeadsign().isEmpty)
    }
}
