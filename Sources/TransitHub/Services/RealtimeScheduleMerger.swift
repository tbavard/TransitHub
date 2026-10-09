import Foundation

// MARK: - RealtimeScheduleMerger
//
// Pure logic that overlays GTFS-RT trip updates on a stop's static schedule,
// so each departure carries its own live delay / cancellation instead of the
// route-wide average used by the Alerts tab. No I/O — unit-testable.

enum RealtimeScheduleMerger {

    /// A trip update is only applied to departures scheduled within this
    /// window around now. trip_ids repeat every service day, so this keeps
    /// today's 25:10 run from inheriting the update of yesterday's run that is
    /// operating right now (shifted to 01:10).
    static let matchWindow: TimeInterval = 6 * 3600

    /// - Parameters:
    ///   - updates: trip updates of the stop's provider, keyed by trip_id.
    ///   - stopId: the stop the entries belong to.
    static func apply(_ updates: [String: TripUpdate],
                      to entries: [ScheduleEntry],
                      stopId: String,
                      now: Date = Date()) -> [ScheduleEntry] {
        guard !updates.isEmpty else { return entries }
        let midnight = Calendar.current.startOfDay(for: now)
        return entries.map { entry in
            guard let update = updates[entry.tripId],
                  let scheduled = scheduledDate(of: entry, midnight: midnight),
                  abs(scheduled.timeIntervalSince(now)) < matchWindow
            else { return entry }
            var live = entry
            live.realtime = status(for: entry, stopId: stopId, update: update, scheduled: scheduled)
            return live
        }
    }

    /// Live status of one departure, or nil when the update says nothing
    /// usable about this stop.
    static func status(for entry: ScheduleEntry,
                       stopId: String,
                       update: TripUpdate,
                       scheduled: Date) -> RealtimeStatus? {
        if update.isCanceled { return .canceled }

        // 1. An update for this very stop.
        if let own = update.stopTimeUpdates.first(where: { matches($0, entry: entry, stopId: stopId) }) {
            if own.isSkipped { return .skipped }
            if let delay = own.departureDelay ?? own.arrivalDelay {
                return .delay(seconds: delay)
            }
            if let predicted = own.departureTime ?? own.arrivalTime {
                return .delay(seconds: Int(predicted.timeIntervalSince(scheduled)))
            }
            return nil
        }

        // 2. GTFS-RT propagation rule: a stop without its own update inherits
        //    the delay of the nearest preceding updated stop. Only possible
        //    with relative delays (absolute times would need that other
        //    stop's scheduled time) and known stop sequences.
        guard let seq = entry.stopSequence else { return nil }
        let preceding = update.stopTimeUpdates
            .filter { $0.stopSequence > 0 && $0.stopSequence < seq && !$0.isSkipped }
            .max { $0.stopSequence < $1.stopSequence }
        if let delay = preceding?.departureDelay ?? preceding?.arrivalDelay {
            return .delay(seconds: delay)
        }
        return nil
    }

    // MARK: - Helpers

    /// Matches by stop_sequence when both sides have one (a loop route visits
    /// the same stop twice), by stop_id otherwise. Sequence 0 is treated as
    /// "absent" because the decoder can't distinguish it from a missing field.
    private static func matches(_ stu: StopTimeUpdate, entry: ScheduleEntry, stopId: String) -> Bool {
        if stu.stopSequence > 0, let seq = entry.stopSequence, seq > 0 {
            return stu.stopSequence == seq
        }
        return stu.stopId == stopId
    }

    /// Absolute scheduled date of a departure on today's clock (times ≥ 24:00
    /// land tomorrow).
    static func scheduledDate(of entry: ScheduleEntry, midnight: Date) -> Date? {
        let parts = entry.departureTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let seconds = parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)
        return midnight.addingTimeInterval(TimeInterval(seconds))
    }
}
