import XCTest
@testable import TransitHub

final class RealtimeAggregatorTests: XCTestCase {

    func testDelaysSortedByWorstFirst() {
        let delays = [
            RouteDelay(id: "a", routeId: "a", avgDelaySeconds: 120, delayedTripCount: 1, totalTripCount: 5),
            RouteDelay(id: "b", routeId: "b", avgDelaySeconds: 600, delayedTripCount: 3, totalTripCount: 4),
            RouteDelay(id: "c", routeId: "c", avgDelaySeconds: 300, delayedTripCount: 2, totalTripCount: 6),
        ]
        let sorted = RealtimeAggregator.sortedDelays(delays)
        XCTAssertEqual(sorted.map(\.id), ["b", "c", "a"])
    }

    func testAlertsSortedByHighestSeverityFirst() {
        let alerts = [
            makeAlert(id: "info", type: "Information"),        // severity 1
            makeAlert(id: "crit", type: "Perturbation majeure"), // severity 3
            makeAlert(id: "warn", type: "Travaux"),            // severity 2
        ]
        let sorted = RealtimeAggregator.sortedAlerts(alerts)
        XCTAssertEqual(sorted.first?.id, "crit")
        XCTAssertEqual(sorted.last?.id, "info")
    }

    func testEmptyInputsReturnEmpty() {
        XCTAssertTrue(RealtimeAggregator.sortedDelays([]).isEmpty)
        XCTAssertTrue(RealtimeAggregator.sortedAlerts([]).isEmpty)
    }

    // MARK: - Helpers

    private func makeAlert(id: String, type: String) -> ServiceAlert {
        ServiceAlert(
            id: id, title: id, body: "", type: type,
            affectedRouteIds: [], affectedStopCodes: [], fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
