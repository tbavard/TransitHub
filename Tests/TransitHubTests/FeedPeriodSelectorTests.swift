import XCTest
@testable import TransitHub

final class FeedPeriodSelectorTests: XCTestCase {

    // MARK: - Day keys

    func testDayKeyFromISOVariants() {
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "2026-10-01"), "20261001")
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "2026-10-01T00:00:00Z"), "20261001")
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "20261001"), "20261001")
        XCTAssertNil(FeedPeriodSelector.dayKey(fromISO: "oops"))
        XCTAssertNil(FeedPeriodSelector.dayKey(fromISO: nil))
    }

    func testDayKeyFromDate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        XCTAssertEqual(FeedPeriodSelector.dayKey(date), "20261014")
    }

    // MARK: - Covering snapshot (RTL scenario: today Oct 14, new feed from Oct 16)

    func testPicksSnapshotCoveringToday() {
        let datasets = [
            ds("new", start: "2026-10-16", end: "2026-11-01", downloaded: "2026-10-09T14:41:00Z"),
            ds("current", start: "2026-08-25", end: "2026-10-15", downloaded: "2026-08-20T10:00:00Z"),
            ds("old", start: "2026-06-20", end: "2026-08-24", downloaded: "2026-06-15T10:00:00Z"),
        ]
        XCTAssertEqual(FeedPeriodSelector.covering(datasets, day: "20261014")?.id, "current")
    }

    func testPrefersMostRecentlyDownloadedAmongCovering() {
        let datasets = [
            ds("first", start: "2026-08-25", end: "2026-10-15", downloaded: "2026-08-20T10:00:00Z"),
            ds("fixed", start: "2026-08-25", end: "2026-10-15", downloaded: "2026-09-02T10:00:00Z"),
        ]
        XCTAssertEqual(FeedPeriodSelector.covering(datasets, day: "20261014")?.id, "fixed")
    }

    func testRangeBoundsAreInclusive() {
        let datasets = [ds("a", start: "2026-08-25", end: "2026-10-15", downloaded: "x")]
        XCTAssertNotNil(FeedPeriodSelector.covering(datasets, day: "20260825"))
        XCTAssertNotNil(FeedPeriodSelector.covering(datasets, day: "20261015"))
        XCTAssertNil(FeedPeriodSelector.covering(datasets, day: "20261016"))
    }

    func testIgnoresSnapshotsWithoutURLOrDates() {
        let datasets = [
            ds("noURL", start: "2026-08-25", end: "2026-10-15", downloaded: "x", url: nil),
            ds("noDates", start: nil, end: nil, downloaded: "x"),
        ]
        XCTAssertNil(FeedPeriodSelector.covering(datasets, day: "20261014"))
    }

    // MARK: - Start day of an extracted feed

    func testStartDayIsEarliestOfCalendarAndAddedDates() {
        XCTAssertEqual(
            FeedPeriodSelector.startDay(calendarStartDates: ["20261016", "20261020"],
                                        addedExceptionDates: ["20261013"]),
            "20261013")
        XCTAssertEqual(
            FeedPeriodSelector.startDay(calendarStartDates: ["20261016"], addedExceptionDates: []),
            "20261016")
        XCTAssertNil(FeedPeriodSelector.startDay(calendarStartDates: [], addedExceptionDates: ["bad"]))
    }

    // MARK: - Helpers

    private func ds(_ id: String, start: String?, end: String?, downloaded: String,
                    url: String? = "https://files.mobilitydatabase.org/x.zip") -> MDBLatestDataset {
        MDBLatestDataset(id: id, hosted_url: url, downloaded_at: downloaded, hash: nil,
                         service_date_range_start: start, service_date_range_end: end,
                         agency_timezone: nil, zipped_folder_size_mb: nil)
    }
}
