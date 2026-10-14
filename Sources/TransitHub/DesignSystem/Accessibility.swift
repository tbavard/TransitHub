import Foundation

// MARK: - Accessibility (VoiceOver) phrasing
//
// Composite views (pills, countdowns, minute chips, hero cards) are read as
// one sentence instead of a string of fragments ("24", "4", "min"). These
// helpers build the localized pieces so every screen phrases departures the
// same way.

enum A11y {

    static func route(_ shortName: String) -> String {
        String(format: String(localized: "a11y.route"), shortName)
    }

    static func towards(_ headsign: String) -> String? {
        headsign.isEmpty ? nil : String(format: String(localized: "a11y.towards"), headsign)
    }

    static func countdown(_ minutes: Int) -> String {
        minutes <= 0
            ? String(localized: "a11y.now")
            : String(format: String(localized: "a11y.in_minutes"), minutes)
    }

    static func countdowns(_ minutes: [Int]) -> String {
        minutes.map(countdown).joined(separator: ", ")
    }

    /// "live, 3 minutes late" / "canceled" / nil for timetable-only data.
    static func liveStatus(of entry: ScheduleEntry) -> String? {
        if entry.isCanceled { return String(localized: "a11y.canceled") }
        guard entry.delaySeconds != nil else { return nil }
        let m = entry.delayMinutes
        let detail: String
        if m >= 1 {
            detail = String(format: String(localized: "a11y.late"), m)
        } else if m <= -1 {
            detail = String(format: String(localized: "a11y.early"), -m)
        } else {
            detail = String(localized: "a11y.on_time")
        }
        return join([String(localized: "a11y.live"), detail])
    }

    /// Joins non-empty parts into one spoken sentence.
    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
