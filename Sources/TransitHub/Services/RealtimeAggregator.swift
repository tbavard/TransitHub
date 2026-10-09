import Foundation

// MARK: - RealtimeAggregator
//
// Pure merge/sort logic for realtime data collected across providers, extracted
// from AppViewModel.refreshRealtime so the ordering rules are unit-testable
// without any network access.

enum RealtimeAggregator {
    /// Route delays sorted by worst average delay first.
    static func sortedDelays(_ delays: [RouteDelay]) -> [RouteDelay] {
        delays.sorted { $0.avgDelaySeconds > $1.avgDelaySeconds }
    }

    /// Service alerts sorted by highest severity first.
    static func sortedAlerts(_ alerts: [ServiceAlert]) -> [ServiceAlert] {
        alerts.sorted { $0.severityLevel > $1.severityLevel }
    }
}
