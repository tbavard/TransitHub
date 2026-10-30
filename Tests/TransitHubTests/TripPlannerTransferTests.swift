import XCTest
import CoreLocation
@testable import TransitHub

/// End-to-end tests of the single-network planner against a tiny temporary
/// GTFS database: A --R1--> B (transfer) --R2--> D.
final class TripPlannerTransferTests: XCTestCase {

    private let stopA = Stop(id: "A", name: "A", lat: 45.5000, lon: -73.6000,
                             locationType: 0, parentStation: nil, providerId: "test")
    private let stopB = Stop(id: "B", name: "B", lat: 45.5100, lon: -73.6000,
                             locationType: 0, parentStation: nil, providerId: "test")
    private let stopD = Stop(id: "D", name: "D", lat: 45.5200, lon: -73.6000,
                             locationType: 0, parentStation: nil, providerId: "test")

    /// Builds the fixture network in a throwaway database and returns its provider id.
    /// `secondLegs` are the departure times from B of the R2 trips (each arrives at D 15 min later).
    private func makeNetwork(secondLegs: [String]) throws -> String {
        let pid = "test-plan-\(UUID().uuidString)"
        var stops = [stopA, stopB, stopD]
        for i in stops.indices { stops[i].providerId = pid }

        let db = GTFSDatabase.forProviderId(pid)
        try db.open()
        defer { db.close() }
        try db.createSchema()
        addTeardownBlock { _ = try? GTFSDatabase.forProviderId(pid).deleteDatabase() }

        for s in stops { try db.insertStop(s) }
        try db.insertRoute(Route(gtfsId: "R1", agencyId: "", shortName: "1", longName: "First",
                                 type: 3, color: "FF0000", textColor: "FFFFFF", providerId: pid))
        try db.insertRoute(Route(gtfsId: "R2", agencyId: "", shortName: "2", longName: "Second",
                                 type: 3, color: "0000FF", textColor: "FFFFFF", providerId: pid))
        try db.insertCalendar(ServiceCalendar(serviceId: "S",
                                              monday: true, tuesday: true, wednesday: true,
                                              thursday: true, friday: true, saturday: true, sunday: true,
                                              startDate: "20200101", endDate: "20991231"))

        try db.insertTrip(id: "T1", routeId: "R1", serviceId: "S", headsign: "To B", directionId: 0)
        try db.prepareStopTimeInsert()
        defer { db.finalizeStopTimeInsert() }
        db.insertStopTime(tripId: "T1", stopId: "A", arrival: "10:00:00", departure: "10:00:00", seq: 1)
        db.insertStopTime(tripId: "T1", stopId: "B", arrival: "10:10:00", departure: "10:10:00", seq: 2)

        for (i, dep) in secondLegs.enumerated() {
            let id = "T2-\(i)"
            try db.insertTrip(id: id, routeId: "R2", serviceId: "S", headsign: "To D", directionId: 0)
            let arr = Self.plus15(dep)
            db.insertStopTime(tripId: id, stopId: "B", arrival: dep, departure: dep, seq: 1)
            db.insertStopTime(tripId: id, stopId: "D", arrival: arr, departure: arr, seq: 2)
        }
        return pid
    }

    private static func plus15(_ time: String) -> String {
        let s = (GTFSTime.seconds(of: time) ?? 0) + 15 * 60
        return GTFSTime.format(seconds: s)
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    private func stops(for pid: String) -> [Stop] {
        [stopA, stopB, stopD].map { s in
            var copy = s
            copy.providerId = pid
            return copy
        }
    }

    // MARK: - Tests

    func testFindsOneTransferTrip() async throws {
        // R2 leaves B at 10:05 (before R1 arrives: unusable) and 10:20 (usable).
        let pid = try makeNetwork(secondLegs: ["10:05:00", "10:20:00"])
        let all = stops(for: pid)

        let result = try await TripPlanner.plan(
            from: .stop(all[0]), to: .stop(all[2]), providerId: pid,
            allStops: all, userLocation: nil, departAt: at(9, 55))

        XCTAssertEqual(result.count, 1)
        let itin = try XCTUnwrap(result.first)
        XCTAssertEqual(itin.transitLegs.map(\.routeShortName), ["1", "2"])
        XCTAssertEqual(itin.transitLegs.last?.tripId, "T2-1")
        XCTAssertEqual(itin.arrivalDate, at(10, 35))
        XCTAssertEqual(itin.departureDate, at(10, 0))
    }

    func testRejectsTransferWithoutEnoughTimeToConnect() async throws {
        // R2 leaves B one minute after R1 arrives: inside the 2-minute buffer.
        let pid = try makeNetwork(secondLegs: ["10:11:00"])
        let all = stops(for: pid)

        do {
            _ = try await TripPlanner.plan(
                from: .stop(all[0]), to: .stop(all[2]), providerId: pid,
                allStops: all, userLocation: nil, departAt: at(9, 55))
            XCTFail("Expected noRouteFound")
        } catch let error as TripPlanError {
            guard case .noRouteFound = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testIgnoresStopsOfOtherNetworks() async throws {
        let pid = try makeNetwork(secondLegs: ["10:20:00"])
        // Same stops, but the caller plans on a different network.
        let all = stops(for: pid)

        do {
            _ = try await TripPlanner.plan(
                from: .stop(all[0]), to: .stop(all[2]), providerId: "someone-else",
                allStops: all, userLocation: nil, departAt: at(9, 55))
            XCTFail("Expected an error")
        } catch let error as TripPlanError {
            guard case .noStopsNearOrigin = error else { return XCTFail("Wrong error: \(error)") }
        }
    }
}
