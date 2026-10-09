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

    func testInterpolationFillsGapsLinearlyByStopCount() {
        let filled = GTFSTime.interpolated(["08:00:00", nil, nil, "08:09:00"])
        XCTAssertEqual(filled, ["08:00:00", "08:03:00", "08:06:00", "08:09:00"])
    }

    func testInterpolationHandlesSeveralGapsAndOvernight() {
        let filled = GTFSTime.interpolated(["23:58:00", nil, "24:02:00", nil, "24:10:00"])
        XCTAssertEqual(filled, ["23:58:00", "24:00:00", "24:02:00", "24:06:00", "24:10:00"])
    }

    func testInterpolationLeavesUnanchoredEndsNil() {
        let filled = GTFSTime.interpolated([nil, "08:00:00", nil])
        XCTAssertEqual(filled, [nil, "08:00:00", nil])
    }

    func testInterpolationKeepsFullyTimedTripUnchanged() {
        let times: [String?] = ["08:00:00", "08:05:30", "08:07:00"]
        XCTAssertEqual(GTFSTime.interpolated(times), times)
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
