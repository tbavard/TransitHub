import XCTest
import CoreLocation
@testable import TransitHub

final class TripPlannerTests: XCTestCase {

    // MARK: - gtfsTimeString

    func testGtfsTimeStringFormatsHourMinuteSecond() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 8
        comps.hour = 8; comps.minute = 7; comps.second = 3
        let d = Calendar.current.date(from: comps)!
        XCTAssertEqual(TripPlanner.gtfsTimeString(from: d), "08:07:03")
    }

    // MARK: - absoluteDate

    func testAbsoluteDateResolvesSameDayTime() {
        let ref = makeDate(year: 2026, month: 5, day: 8, hour: 10, minute: 0)
        let resolved = TripPlanner.absoluteDate(for: "14:30:00", reference: ref)
        let expected = makeDate(year: 2026, month: 5, day: 8, hour: 14, minute: 30)
        XCTAssertEqual(resolved, expected)
    }

    func testAbsoluteDateHandlesOvernightGTFSTime() {
        // "25:30:00" represents 1:30 the NEXT calendar day relative to the
        // GTFS service day that anchors `reference`.
        let ref = makeDate(year: 2026, month: 5, day: 8, hour: 23, minute: 0)
        let resolved = TripPlanner.absoluteDate(for: "25:30:00", reference: ref)
        let expected = makeDate(year: 2026, month: 5, day: 9, hour: 1, minute: 30)
        XCTAssertEqual(resolved, expected)
    }

    func testAbsoluteDateFallsBackToReferenceOnInvalidInput() {
        let ref = makeDate(year: 2026, month: 5, day: 8, hour: 10, minute: 0)
        XCTAssertEqual(TripPlanner.absoluteDate(for: "not-a-time", reference: ref), ref)
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = 0
        return Calendar.current.date(from: c)!
    }
}

// MARK: - WalkLeg / TransitLeg math

final class TripLegMathTests: XCTestCase {

    func testWalkMinutesUsesEightyMetersPerMinute() {
        let w = WalkLeg(
            fromName: "A", toName: "B",
            fromCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            toCoordinate:   CLLocationCoordinate2D(latitude: 0, longitude: 0),
            distanceMeters: 320
        )
        // 320 / 80 = 4 min
        XCTAssertEqual(w.walkMinutes, 4)
    }

    func testWalkMinutesFloorsToOneForShortDistances() {
        let w = WalkLeg(
            fromName: "A", toName: "B",
            fromCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            toCoordinate:   CLLocationCoordinate2D(latitude: 0, longitude: 0),
            distanceMeters: 10
        )
        XCTAssertEqual(w.walkMinutes, 1)
    }

    func testTransitOnboardMinutesSameDay() {
        let stopA = Stop(id: "1", name: "A", lat: 0, lon: 0,
                         locationType: 0, parentStation: nil, providerId: "stm")
        let stopB = Stop(id: "2", name: "B", lat: 0, lon: 0,
                         locationType: 0, parentStation: nil, providerId: "stm")
        let leg = TransitLeg(
            providerId: "stm", routeId: "r", routeShortName: "55",
            routeLongName: "long", routeColor: "000000", headsign: "Nord",
            fromStop: stopA, toStop: stopB,
            departureTime: "10:00:00", arrivalTime: "10:23:00",
            tripId: "t1", numStops: 5
        )
        XCTAssertEqual(leg.onboardMinutes, 23)
    }

    func testTransitOnboardMinutesWrapsOvernight() {
        // departure 23:55, arrival 00:15 → 20 minutes (wraps past midnight)
        let stopA = Stop(id: "1", name: "A", lat: 0, lon: 0,
                         locationType: 0, parentStation: nil, providerId: "stm")
        let stopB = Stop(id: "2", name: "B", lat: 0, lon: 0,
                         locationType: 0, parentStation: nil, providerId: "stm")
        let leg = TransitLeg(
            providerId: "stm", routeId: "r", routeShortName: "55",
            routeLongName: "long", routeColor: "000000", headsign: "Nord",
            fromStop: stopA, toStop: stopB,
            departureTime: "23:55:00", arrivalTime: "00:15:00",
            tripId: "t1", numStops: 3
        )
        XCTAssertEqual(leg.onboardMinutes, 20)
    }
}
