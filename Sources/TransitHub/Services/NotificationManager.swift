import Foundation
import UserNotifications
import os

/// Thin wrapper around UNUserNotificationCenter for scheduling the two local
/// notifications the app needs for Go mode:
///   - "Time to leave" (departure time minus walking time)
///   - "Vehicle approaching" (2 minutes before scheduled boarding)
///
/// Permission is requested lazily the first time a notification is scheduled.
/// A deliberate no-op if the user has denied authorization — we don't re-prompt.
final class NotificationManager {

    static let shared = NotificationManager()
    private init() {}

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.transithub", category: "Notifications")

    // MARK: - Authorization

    /// Requests alert + sound permission. Returns true if authorized. Safe to call repeatedly.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    // MARK: - Scheduling

    /// Schedules a "time to leave" notification at `fireDate`. No-op if `fireDate`
    /// is in the past or authorization is denied.
    func scheduleTimeToLeave(
        id: String,
        fireDate: Date,
        stopName: String,
        routeShortName: String,
        walkMinutes: Int
    ) async {
        guard fireDate.timeIntervalSinceNow > 0 else { return }
        guard await requestAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "notif.leave_now.title")
        content.body = String(
            format: String(localized: "notif.leave_now.body"),
            walkMinutes, routeShortName, stopName
        )
        content.sound = .default
        content.categoryIdentifier = "GO_LEAVE_NOW"
        content.threadIdentifier = "stm.go"

        await schedule(id: id, fireDate: fireDate, content: content)
    }

    /// Schedules an "approaching" notification at `fireDate` (typically 2 minutes
    /// before scheduled boarding). No-op if in the past or denied.
    func scheduleVehicleApproaching(
        id: String,
        fireDate: Date,
        stopName: String,
        routeShortName: String,
        headsign: String,
        minutes: Int
    ) async {
        guard fireDate.timeIntervalSinceNow > 0 else { return }
        guard await requestAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = String(
            format: String(localized: "notif.approaching.title"),
            routeShortName
        )
        content.body = String(
            format: String(localized: "notif.approaching.body"),
            minutes, headsign, stopName
        )
        content.sound = .default
        content.categoryIdentifier = "GO_APPROACHING"
        content.threadIdentifier = "stm.go"

        await schedule(id: id, fireDate: fireDate, content: content)
    }

    // MARK: - Cancellation

    func cancel(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    // MARK: - Private

    private func schedule(id: String, fireDate: Date, content: UNNotificationContent) async {
        let interval = max(1, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            logger.error("schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
