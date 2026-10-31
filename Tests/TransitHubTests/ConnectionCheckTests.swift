import XCTest
@testable import TransitHub

final class ConnectionCheckTests: XCTestCase {

    private let arrival = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlentyOfTimeIsSafe() {
        // Ride ends at T, 2 min walk, next vehicle at T+10 min.
        XCTAssertFalse(ConnectionCheck.isAtRisk(
            arrival: arrival, walkSeconds: 120,
            nextBoarding: arrival.addingTimeInterval(600)))
    }

    func testALateArrivalPutsTheConnectionAtRisk() {
        // The first ride is 9 min late: it now ends 1 min before the next one leaves.
        XCTAssertTrue(ConnectionCheck.isAtRisk(
            arrival: arrival.addingTimeInterval(540), walkSeconds: 120,
            nextBoarding: arrival.addingTimeInterval(600)))
    }

    func testTheWalkIsPartOfTheBudget() {
        let boarding = arrival.addingTimeInterval(300)
        XCTAssertFalse(ConnectionCheck.isAtRisk(arrival: arrival, walkSeconds: 60, nextBoarding: boarding))
        XCTAssertTrue(ConnectionCheck.isAtRisk(arrival: arrival, walkSeconds: 300, nextBoarding: boarding))
    }

    func testSlackKeepsAnExactlyTightConnectionFlagged() {
        // Arriving exactly when the walk would end leaves no margin: at risk.
        let walk = 120
        XCTAssertTrue(ConnectionCheck.isAtRisk(
            arrival: arrival, walkSeconds: walk,
            nextBoarding: arrival.addingTimeInterval(TimeInterval(walk))))
    }
}
