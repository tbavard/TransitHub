import Foundation

// MARK: - Feed period selection
//
// Agencies sometimes publish their next service period before it starts
// (RTL: the downloadable feed covered Oct 16 – Nov 1 while it was Oct 14),
// leaving nothing to show today. MobilityDatabase keeps every snapshot of a
// feed with its service date range; these pure helpers pick the snapshot
// that covers a given day. Dates are compared as "yyyyMMdd" strings.

enum FeedPeriodSelector {

    /// Day key ("yyyyMMdd") of `date` in the device's time zone — the same
    /// form as GTFS calendar dates.
    static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-10-01", "2026-10-01T00:00:00Z" or "20261001" → "20261001".
    static func dayKey(fromISO s: String?) -> String? {
        guard let s else { return nil }
        let digits = s.prefix(10).filter(\.isNumber)
        return digits.count == 8 ? String(digits) : nil
    }

    /// The snapshot whose service range contains `day`, preferring the most
    /// recently downloaded one (latest corrections for that period). Only
    /// snapshots with a downloadable hosted ZIP qualify.
    static func covering(_ datasets: [MDBLatestDataset], day: String) -> MDBLatestDataset? {
        datasets
            .filter { ds in
                guard ds.hosted_url?.hasPrefix("http") == true,
                      let start = dayKey(fromISO: ds.service_date_range_start),
                      let end = dayKey(fromISO: ds.service_date_range_end)
                else { return false }
                return start <= day && day <= end
            }
            .max { ($0.downloaded_at ?? "") < ($1.downloaded_at ?? "") }
    }

    /// Earliest service day declared by an extracted GTFS feed: MIN of
    /// calendar.start_date and of calendar_dates added dates (exception 1).
    static func startDay(calendarStartDates: [String], addedExceptionDates: [String]) -> String? {
        (calendarStartDates + addedExceptionDates)
            .filter { $0.count == 8 && $0.allSatisfy(\.isNumber) }
            .min()
    }
}
