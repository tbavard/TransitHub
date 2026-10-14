import XCTest
@testable import TransitHub

final class FeedPeriodSelectorTests: XCTestCase {

    // MARK: - Day keys

    private let montreal = TimeZone(identifier: "America/Montreal")!
    private let paris = TimeZone(identifier: "Europe/Paris")!

    func testDayKeyFromPlainDates() {
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "2026-10-01"), "20261001")
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "20261001"), "20261001")
        XCTAssertNil(FeedPeriodSelector.dayKey(fromISO: "oops"))
        XCTAssertNil(FeedPeriodSelector.dayKey(fromISO: nil))
    }

    func testInstantsAreConvertedToAgencyLocalDay() {
        // Real MobilityDatabase values for RTL (mdb-751).
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "2026-10-16T04:00:00Z", timeZone: montreal), "20261016")
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "2026-11-02T04:59:00Z", timeZone: montreal), "20261101")
        // East of UTC the UTC date is the day before.
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "2026-10-15T22:00:00Z", timeZone: paris), "20261016")
        // Fractional seconds, as in `downloaded_at`.
        XCTAssertEqual(FeedPeriodSelector.dayKey(fromISO: "2026-10-14T00:36:39.83603Z", timeZone: montreal), "20261013")
    }

    func testDayKeyFromDate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        XCTAssertEqual(FeedPeriodSelector.dayKey(date), "20261014")
    }

    // MARK: - Covering snapshot

    func testRealRTLSnapshotsOnOctober14() {
        // First three items of GET /gtfs_feeds/mdb-751/datasets on 2026-10-14.
        let datasets = [
            ds("mdb-751-202610140036", start: "2026-10-16T04:00:00Z", end: "2026-11-02T04:59:00Z",
               downloaded: "2026-10-14T00:36:39.83603Z", tz: "America/Montreal"),
            ds("mdb-751-202609180021", start: "2026-09-23T04:00:00Z", end: "2026-11-02T04:59:00Z",
               downloaded: "2026-09-18T00:21:41Z", tz: "America/Montreal"),
            ds("mdb-751-202608010005", start: "2026-08-24T04:00:00Z", end: "2026-11-02T04:59:00Z",
               downloaded: "2026-08-01T00:06:02Z", tz: "America/Montreal"),
        ]
        XCTAssertEqual(FeedPeriodSelector.covering(datasets, day: "20261014")?.id, "mdb-751-202609180021")
        // From Oct 16 the newest snapshot (= producer feed) covers the day itself.
        XCTAssertEqual(FeedPeriodSelector.covering(datasets, day: "20261016")?.id, "mdb-751-202610140036")
        // Nov 2 is past every range once converted to Montreal time.
        XCTAssertNil(FeedPeriodSelector.covering(datasets, day: "20261102"))
    }

    // Synthetic scenario: today Oct 14, new feed from Oct 16.

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
                    url: String? = "https://files.mobilitydatabase.org/x.zip",
                    tz: String? = nil) -> MDBLatestDataset {
        MDBLatestDataset(id: id, hosted_url: url, downloaded_at: downloaded, hash: nil,
                         service_date_range_start: start, service_date_range_end: end,
                         agency_timezone: tz, zipped_folder_size_mb: nil)
    }
}
