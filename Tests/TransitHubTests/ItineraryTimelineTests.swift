import XCTest
import CoreLocation
@testable import TransitHub

final class ItineraryTimelineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func stop(_ id: String) -> Stop {
        Stop(id: id, name: id, lat: 0, lon: 0, locationType: 0, parentStation: nil, providerId: "t")
    }

    private func walk(minutes: Int) -> WalkLeg {
        WalkLeg(fromName: "A", toName: "B",
                fromCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                toCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                distanceMeters: Double(minutes) * 80)
    }

    private func ride(boardsAt: Date, from: String, to: String, durationMinutes: Int) -> TransitLeg {
        TransitLeg(
            providerId: "t", routeId: "r", routeShortName: "55", routeLongName: "",
            routeColor: "FF0000", headsign: "Nord",
            fromStop: stop(from), toStop: stop(to),
            departureTime: "10:00:00",
            arrivalTime: GTFSTime.format(seconds: 10 * 3600 + durationMinutes * 60),
            tripId: "trip", numStops: 5, liveDelaySeconds: nil,
            scheduledDeparture: boardsAt, fromStopSequence: 1)
    }

    func testWalkThenRideAreLaidOutBackToBack() {
        let w = walk(minutes: 2)
        let r = ride(boardsAt: t0.addingTimeInterval(120), from: "A", to: "B", durationMinutes: 20)
        let itin = TripItinerary(legs: [.walk(w), .transit(r)],
                                 departureDate: t0, arrivalDate: t0.addingTimeInterval(22 * 60))

        let segments = ItineraryTimeline.segments(for: itin)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, t0)
        XCTAssertEqual(segments[0].end, t0.addingTimeInterval(120))
        XCTAssertEqual(segments[1].start, t0.addingTimeInterval(120))
        XCTAssertEqual(segments[1].end, t0.addingTimeInterval(120 + 20 * 60))
        XCTAssertNil(segments[0].transit)
        XCTAssertNotNil(segments[1].transit)
    }

    func testWaitingAtTheStopLeavesAGapBeforeTheRide() {
        // The bus leaves 10 minutes after the walk ends.
        let w = walk(minutes: 2)
        let r = ride(boardsAt: t0.addingTimeInterval(12 * 60), from: "A", to: "B", durationMinutes: 15)
        let itin = TripItinerary(legs: [.walk(w), .transit(r)],
                                 departureDate: t0, arrivalDate: t0.addingTimeInterval(27 * 60))

        let segments = ItineraryTimeline.segments(for: itin)

        XCTAssertEqual(segments[1].start, t0.addingTimeInterval(12 * 60))
        XCTAssertGreaterThan(segments[1].start, segments[0].end)
    }

    func testAxisSpansEveryItinerary() {
        let a = TripItinerary(legs: [], departureDate: t0, arrivalDate: t0.addingTimeInterval(1_800))
        let b = TripItinerary(legs: [], departureDate: t0.addingTimeInterval(600),
                              arrivalDate: t0.addingTimeInterval(3_000))

        let axis = ItineraryTimeline.axis(for: [a, b])

        XCTAssertEqual(axis?.start, t0)
        XCTAssertEqual(axis?.end, t0.addingTimeInterval(3_000))
        XCTAssertNil(ItineraryTimeline.axis(for: []))
    }
}
