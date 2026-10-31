import XCTest
@testable import TransitHub

/// RTL published its next period (Nov 2) while the current one runs until
/// Nov 1: the installed schedules must survive until then.
final class KeepInstalledScheduleTests: XCTestCase {

    func testInstalledSchedulesCoveringTodayAreKept() {
        XCTAssertTrue(FeedPeriodSelector.canKeepInstalled(
            feedStart: "20261016", feedEnd: "20261101", today: "20261030"))
    }

    func testBoundsAreInclusive() {
        XCTAssertTrue(FeedPeriodSelector.canKeepInstalled(
            feedStart: "20261016", feedEnd: "20261101", today: "20261016"))
        XCTAssertTrue(FeedPeriodSelector.canKeepInstalled(
            feedStart: "20261016", feedEnd: "20261101", today: "20261101"))
    }

    func testExpiredSchedulesAreNotKept() {
        XCTAssertFalse(FeedPeriodSelector.canKeepInstalled(
            feedStart: "20261016", feedEnd: "20261101", today: "20261102"))
    }

    func testFutureOnlySchedulesAreNotKept() {
        // A database that itself starts later has nothing to show today.
        XCTAssertFalse(FeedPeriodSelector.canKeepInstalled(
            feedStart: "20261102", feedEnd: "20270103", today: "20261030"))
    }

    func testMissingDatesAreNotKept() {
        XCTAssertFalse(FeedPeriodSelector.canKeepInstalled(feedStart: nil, feedEnd: "20261101", today: "20261030"))
        XCTAssertFalse(FeedPeriodSelector.canKeepInstalled(feedStart: "20261016", feedEnd: nil, today: "20261030"))
    }

    func testArchiveStillCoversTodayWhenTheNewPeriodIsPublished() {
        // MDB listing once RTL's Nov 2 period is out: the newest snapshot does
        // not cover Oct 30, the previous one does.
        let datasets = [
            ds("mdb-751-new", start: "2026-11-02T05:00:00Z", end: "2027-01-04T04:59:00Z",
               downloaded: "2026-10-28T00:30:00Z"),
            ds("mdb-751-202610140036", start: "2026-10-16T04:00:00Z", end: "2026-11-02T04:59:00Z",
               downloaded: "2026-10-14T00:36:39.83603Z"),
        ]
        XCTAssertEqual(FeedPeriodSelector.covering(datasets, day: "20261030")?.id, "mdb-751-202610140036")
        XCTAssertEqual(FeedPeriodSelector.covering(datasets, day: "20261102")?.id, "mdb-751-new")
    }

    private func ds(_ id: String, start: String, end: String, downloaded: String) -> MDBLatestDataset {
        MDBLatestDataset(id: id, hosted_url: "https://files.mobilitydatabase.org/x.zip",
                         downloaded_at: downloaded, hash: nil,
                         service_date_range_start: start, service_date_range_end: end,
                         agency_timezone: "America/Montreal", zipped_folder_size_mb: nil)
    }
}
