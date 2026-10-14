import XCTest
@testable import TransitHub

final class RealtimeScheduleMergerTests: XCTestCase {

    // Fixed "now": today at 08:00 local time.
    private let now = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!

    // MARK: - Own-stop updates

    func testRelativeDelayAtThisStop() {
        let update = trip(stus: [stu(stop: "S", seq: 5, depDelay: 180)])
        let merged = apply(update, to: entry("08:10:00", seq: 5))
        XCTAssertEqual(merged.realtime, .delay(seconds: 180))
        XCTAssertEqual(merged.delayMinutes, 3)
        XCTAssertEqual(merged.predictedDisplayTime, "08:13")
    }

    func testAbsoluteTimeAtThisStopIsConvertedToDelay() {
        let scheduled = Calendar.current.date(bySettingHour: 8, minute: 10, second: 0, of: now)!
        let update = trip(stus: [stu(stop: "S", seq: 5, depTime: scheduled.addingTimeInterval(240))])
        XCTAssertEqual(apply(update, to: entry("08:10:00", seq: 5)).realtime, .delay(seconds: 240))
    }

    func testMatchesByStopIdWhenSequenceMissing() {
        let update = trip(stus: [stu(stop: "S", seq: 0, depDelay: -60)])
        XCTAssertEqual(apply(update, to: entry("08:10:00", seq: 5)).realtime, .delay(seconds: -60))
    }

    func testSkippedStop() {
        let update = trip(stus: [stu(stop: "S", seq: 5, skipped: true)])
        let merged = apply(update, to: entry("08:10:00", seq: 5))
        XCTAssertEqual(merged.realtime, .skipped)
        XCTAssertTrue(merged.isCanceled)
    }

    func testCanceledTrip() {
        var update = trip(stus: [])
        update.isCanceled = true
        XCTAssertEqual(apply(update, to: entry("08:10:00", seq: 5)).realtime, .canceled)
    }

    // MARK: - Propagation

    func testDelayPropagatesFromNearestPrecedingStop() {
        let update = trip(stus: [
            stu(stop: "A", seq: 1, depDelay: 60),
            stu(stop: "B", seq: 3, depDelay: 300),
            stu(stop: "Z", seq: 9, depDelay: 900),   // after our stop: ignored
        ])
        XCTAssertEqual(apply(update, to: entry("08:10:00", seq: 5)).realtime, .delay(seconds: 300))
    }

    func testNoPropagationFromAbsoluteTimesOnly() {
        let update = trip(stus: [stu(stop: "A", seq: 1, depTime: now)])
        XCTAssertNil(apply(update, to: entry("08:10:00", seq: 5)).realtime)
    }

    // MARK: - Matching window

    func testUpdateIgnoredForSameTripIdFarFromNow() {
        // Tonight's 25:10 run must not inherit the update of a trip running now.
        let update = trip(stus: [stu(stop: "S", seq: 5, depDelay: 120)])
        XCTAssertNil(apply(update, to: entry("25:10:00", seq: 5)).realtime)
    }

    func testEntriesWithoutUpdateAreUntouched() {
        let merged = RealtimeScheduleMerger.apply([:], to: [entry("08:10:00", seq: 5)], stopId: "S", now: now)
        XCTAssertNil(merged.first?.realtime)
    }

    // MARK: - Trip-level lookup (trip planner, Live Activity)

    func testTripLevelStatusMatchesBySequence() {
        let update = trip(stus: [stu(stop: "S", seq: 5, depDelay: 120)])
        let scheduled = Calendar.current.date(bySettingHour: 8, minute: 10, second: 0, of: now)!
        let status = RealtimeScheduleMerger.status(tripId: "T1", stopId: "S", stopSequence: 5,
                                                   scheduled: scheduled, updates: ["T1": update], now: now)
        XCTAssertEqual(status, .delay(seconds: 120))
    }

    func testTripLevelStatusNilForUnknownTrip() {
        let status = RealtimeScheduleMerger.status(tripId: "other", stopId: "S", stopSequence: 5,
                                                   scheduled: now, updates: [:], now: now)
        XCTAssertNil(status)
    }

    // MARK: - Helpers

    private func apply(_ update: TripUpdate, to entry: ScheduleEntry) -> ScheduleEntry {
        RealtimeScheduleMerger.apply([update.id: update], to: [entry], stopId: "S", now: now).first!
    }

    private func entry(_ time: String, seq: Int) -> ScheduleEntry {
        ScheduleEntry(departureTime: time, tripId: "T1", headsign: "Nord", routeId: "24",
                      routeShortName: "24", routeColor: "009EE0", directionId: 0, stopSequence: seq)
    }

    private func trip(stus: [StopTimeUpdate]) -> TripUpdate {
        TripUpdate(id: "T1", routeId: "24", vehicleId: "V", stopTimeUpdates: stus, timestamp: now)
    }

    private func stu(stop: String, seq: Int, depDelay: Int? = nil,
                     depTime: Date? = nil, skipped: Bool = false) -> StopTimeUpdate {
        StopTimeUpdate(stopId: stop, stopSequence: seq, arrivalDelay: nil, departureDelay: depDelay,
                       arrivalTime: nil, departureTime: depTime, isSkipped: skipped)
    }
}
