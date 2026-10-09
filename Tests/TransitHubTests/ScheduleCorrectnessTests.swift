import XCTest
@testable import TransitHub

final class GTFSTimeTests: XCTestCase {

    func testNormalizedPadsSingleDigitHour() {
        XCTAssertEqual(GTFSTime.normalized("8:05:00"), "08:05:00")
        XCTAssertEqual(GTFSTime.normalized(" 8:05:00"), "08:05:00")
    }

    func testNormalizedKeepsPaddedAndOvernightTimes() {
        XCTAssertEqual(GTFSTime.normalized("08:05:00"), "08:05:00")
        XCTAssertEqual(GTFSTime.normalized("25:10:30"), "25:10:30")
    }

    func testNormalizedAddsMissingSeconds() {
        XCTAssertEqual(GTFSTime.normalized("7:30"), "07:30:00")
    }

    func testNormalizedLeavesGarbageAndEmptyAlone() {
        XCTAssertEqual(GTFSTime.normalized(""), "")
        XCTAssertEqual(GTFSTime.normalized("abc"), "abc")
    }

    func testNormalizedTimesSortChronologicallyAsStrings() {
        let sorted = ["23:00:00", "8:05:00", "10:00:00"].map(GTFSTime.normalized).sorted()
        XCTAssertEqual(sorted, ["08:05:00", "10:00:00", "23:00:00"])
    }

    func testShiftFromPreviousDay() {
        XCTAssertEqual(GTFSTime.shiftedFromPreviousDay("25:10:00"), "01:10:00")
        XCTAssertEqual(GTFSTime.shiftedFromPreviousDay("24:00:00"), "00:00:00")
        XCTAssertNil(GTFSTime.shiftedFromPreviousDay("23:59:00"))
    }
}

final class StopPatternMergeTests: XCTestCase {

    func testSinglePatternIsKeptAsIs() {
        XCTAssertEqual(GTFSDatabase.mergedStopOrder([["A", "B", "C"]]), ["A", "B", "C"])
    }

    func testShortTurnAddsNothing() {
        let order = GTFSDatabase.mergedStopOrder([["A", "B"], ["A", "B", "C", "D"]])
        XCTAssertEqual(order, ["A", "B", "C", "D"])
    }

    func testBranchStopsAreInsertedAfterTheirPredecessor() {
        // Trunk A-B-C-D-E; a variant leaves the trunk after B to serve X.
        let order = GTFSDatabase.mergedStopOrder([["A", "B", "C", "D", "E"], ["A", "B", "X", "C"]])
        XCTAssertEqual(order, ["A", "B", "X", "C", "D", "E"])
    }

    func testBranchStartingElsewhereGoesBeforeFirstSharedStop() {
        let order = GTFSDatabase.mergedStopOrder([["A", "B", "C", "D"], ["Z", "C", "D"]])
        XCTAssertEqual(order, ["A", "B", "Z", "C", "D"])
    }

    func testVariantNumberingDoesNotScrambleOrder() {
        // The old MIN(stop_sequence) query put C (seq 1 in the short variant)
        // before B. Pattern merge only depends on relative order within trips.
        let order = GTFSDatabase.mergedStopOrder([["A", "B", "C", "D"], ["C", "D"]])
        XCTAssertEqual(order, ["A", "B", "C", "D"])
    }

    func testLoopRouteListsEachStopOnce() {
        let order = GTFSDatabase.mergedStopOrder([["A", "B", "C", "A"]])
        XCTAssertEqual(order, ["A", "B", "C"])
    }
}
