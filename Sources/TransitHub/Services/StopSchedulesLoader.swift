import Foundation

/// Loads and refreshes the upcoming departures of a set of stops, for screens
/// that list several stops at once (the map's nearby panel, favorites).
///
/// Realtime is applied at read time (`schedule(for:using:)`), never stored, so
/// the 30 s realtime refresh shows up without re-querying SQLite.
@MainActor
final class StopSchedulesLoader: ObservableObject {

    @Published private(set) var schedulesByStop: [String: [ScheduleEntry]] = [:]
    @Published private(set) var isLoading = false

    /// Fetches the timetable of every stop (one DB open per network).
    func load(stops: [Stop], using appVM: AppViewModel) async {
        guard !stops.isEmpty else { return }
        isLoading = true
        schedulesByStop = await appVM.loadSchedules(for: stops)
        isLoading = false
    }

    /// The stop's departures with live predictions merged in.
    func schedule(for stop: Stop, using appVM: AppViewModel) -> [ScheduleEntry] {
        appVM.withRealtime(schedulesByStop[stop.id] ?? [], at: stop)
    }

    /// True until the first result for this stop has arrived.
    func isLoading(_ stop: Stop) -> Bool {
        isLoading && schedulesByStop[stop.id] == nil
    }
}
