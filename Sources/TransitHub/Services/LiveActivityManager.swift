import Foundation
import ActivityKit
import SwiftUI
import os

@MainActor
final class LiveActivityManager: ObservableObject {

    @Published var activeEntry: ScheduleEntry?
    @Published var trackedItineraryId: UUID?
    @Published var isTracking = false

    private var activity: Activity<DepartureAttributes>?
    private var updateTask: Task<Void, Never>?
    private var scheduledNotificationIds: [String] = []

    /// Cached boarding anchor for the active tracking session. Used by
    /// `refreshNow()` to recompute countdown when the app returns to the
    /// foreground without having to re-derive it from the entry/itinerary.
    private var currentBoardingDate: Date?
    private var currentWalkMinutes: Int = 0

    private let logger = Logger(subsystem: "com.transithub", category: "LiveActivity")

    // MARK: - Track a single stop departure

    func startTracking(entry: ScheduleEntry, stop: Stop) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let minutes = minutesFromNow(entry.departureTime)
        guard minutes >= 0 else { return }

        // Reset previous state — only one activity at a time.
        cancelScheduledNotifications()
        updateTask?.cancel()

        let attrs = DepartureAttributes(
            routeShortName: entry.routeShortName,
            routeColor:     entry.routeColor,
            headsign:       entry.headsign,
            stopName:       stop.name
        )
        let state = DepartureAttributes.ContentState(
            minutesUntilDeparture: minutes,
            isDelayed:             false,
            statusMessage:         minuteLabel(minutes)
        )

        do {
            activity = try Activity.request(
                attributes: attrs,
                content: ActivityContent(
                    state: state,
                    staleDate: Calendar.current.date(byAdding: .minute, value: minutes + 2, to: Date())
                ),
                pushType: nil
            )
            activeEntry = entry
            trackedItineraryId = nil
            isTracking  = true
            currentBoardingDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
            currentWalkMinutes = 0
            scheduleUpdates(departureTime: entry.departureTime)
            scheduleDepartureNotifications(for: entry, stop: stop)
        } catch {
            logger.error("Live Activity error: \(String(describing: error))")
        }
    }

    // MARK: - Track a planned itinerary (Go mode)

    /// Starts Go mode for a planned itinerary. Live Activity tracks the first
    /// transit leg's boarding time; notifications fire when it's time to leave
    /// and when the vehicle is approaching.
    func startTracking(itinerary: TripItinerary) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let transit = itinerary.transitLegs.first else { return }

        cancelScheduledNotifications()
        updateTask?.cancel()

        let boardingDate = departureDate(for: itinerary)
        let minutes = max(0, Int(boardingDate.timeIntervalSinceNow / 60))
        let walkToStopMinutes = walkLegBefore(transit: transit, in: itinerary)?.walkMinutes ?? 0

        let attrs = DepartureAttributes(
            routeShortName: transit.routeShortName,
            routeColor:     transit.routeColor,
            headsign:       transit.headsign,
            stopName:       transit.fromStop.name
        )
        let state = DepartureAttributes.ContentState(
            minutesUntilDeparture: minutes,
            isDelayed:             false,
            statusMessage:         goStatusLabel(minutes: minutes, walkMinutes: walkToStopMinutes)
        )

        do {
            activity = try Activity.request(
                attributes: attrs,
                content: ActivityContent(
                    state: state,
                    staleDate: boardingDate.addingTimeInterval(5 * 60)
                ),
                pushType: nil
            )
            activeEntry = nil
            trackedItineraryId = itinerary.id
            isTracking = true
            currentBoardingDate = boardingDate
            currentWalkMinutes = walkToStopMinutes
            scheduleUpdatesForItinerary(boardingDate: boardingDate, walkMinutes: walkToStopMinutes)
            scheduleItineraryNotifications(itinerary: itinerary, walkMinutes: walkToStopMinutes)
        } catch {
            logger.error("Live Activity error: \(String(describing: error))")
        }
    }

    // MARK: - ScenePhase hook

    /// Forces an immediate Live Activity content refresh, matching the periodic
    /// 30s update loop. Call this when the app returns to the foreground so the
    /// countdown doesn't briefly show stale minutes while waiting for the next
    /// scheduled tick.
    func refreshNow() {
        guard isTracking, let boarding = currentBoardingDate else { return }
        let secondsUntil = boarding.timeIntervalSinceNow
        if secondsUntil < -2 * 60 {
            stopTracking()
            return
        }
        let mins = max(0, Int(secondsUntil / 60))
        let label = trackedItineraryId != nil
            ? goStatusLabel(minutes: mins, walkMinutes: currentWalkMinutes)
            : minuteLabel(mins)
        let state = DepartureAttributes.ContentState(
            minutesUntilDeparture: mins,
            isDelayed: false,
            statusMessage: label
        )
        Task { [weak self] in
            await self?.activity?.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    // MARK: - Stop tracking

    func stopTracking() {
        updateTask?.cancel()
        updateTask = nil
        cancelScheduledNotifications()
        Task {
            let finalState = DepartureAttributes.ContentState(
                minutesUntilDeparture: 0,
                isDelayed:             false,
                statusMessage:         String(localized: "live.departed")
            )
            await activity?.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            activity    = nil
            activeEntry = nil
            trackedItineraryId = nil
            isTracking  = false
            currentBoardingDate = nil
            currentWalkMinutes = 0
        }
    }

    // MARK: - Queries

    func isTracking(entry: ScheduleEntry) -> Bool {
        isTracking && activeEntry?.tripId == entry.tripId
    }

    func isTracking(itinerary: TripItinerary) -> Bool {
        isTracking && trackedItineraryId == itinerary.id
    }

    // MARK: - Private helpers — single-departure flow

    private func scheduleUpdates(departureTime: String) {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let mins = minutesFromNow(departureTime)
                if mins < 0 {
                    stopTracking()
                    return
                }
                let state = DepartureAttributes.ContentState(
                    minutesUntilDeparture: mins,
                    isDelayed:             false,
                    statusMessage:         minuteLabel(mins)
                )
                await activity?.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    private func scheduleDepartureNotifications(for entry: ScheduleEntry, stop: Stop) {
        let boarding = Date().addingTimeInterval(TimeInterval(minutesFromNow(entry.departureTime) * 60))
        let approachingAt = boarding.addingTimeInterval(-2 * 60)
        let approachingId = "approach-\(entry.tripId)"
        scheduledNotificationIds.append(approachingId)
        Task {
            await NotificationManager.shared.scheduleVehicleApproaching(
                id: approachingId,
                fireDate: approachingAt,
                stopName: stop.name,
                routeShortName: entry.routeShortName,
                headsign: entry.headsign,
                minutes: 2
            )
        }
    }

    // MARK: - Private helpers — itinerary flow

    private func scheduleUpdatesForItinerary(boardingDate: Date, walkMinutes: Int) {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let secondsUntil = boardingDate.timeIntervalSinceNow
                let mins = max(0, Int(secondsUntil / 60))
                // End the activity a couple of minutes past boarding time —
                // by then the user is either on the bus or missed it.
                if secondsUntil < -2 * 60 {
                    stopTracking()
                    return
                }
                let state = DepartureAttributes.ContentState(
                    minutesUntilDeparture: mins,
                    isDelayed:             false,
                    statusMessage:         goStatusLabel(minutes: mins, walkMinutes: walkMinutes)
                )
                await activity?.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    private func scheduleItineraryNotifications(itinerary: TripItinerary, walkMinutes: Int) {
        guard let transit = itinerary.transitLegs.first else { return }
        let boarding = departureDate(for: itinerary)

        if walkMinutes > 0 {
            let leaveAt = boarding.addingTimeInterval(-TimeInterval(walkMinutes * 60))
            let leaveId = "leave-\(itinerary.id.uuidString)"
            scheduledNotificationIds.append(leaveId)
            Task {
                await NotificationManager.shared.scheduleTimeToLeave(
                    id: leaveId,
                    fireDate: leaveAt,
                    stopName: transit.fromStop.name,
                    routeShortName: transit.routeShortName,
                    walkMinutes: walkMinutes
                )
            }
        }

        let approachingAt = boarding.addingTimeInterval(-2 * 60)
        let approachingId = "approach-\(itinerary.id.uuidString)"
        scheduledNotificationIds.append(approachingId)
        Task {
            await NotificationManager.shared.scheduleVehicleApproaching(
                id: approachingId,
                fireDate: approachingAt,
                stopName: transit.fromStop.name,
                routeShortName: transit.routeShortName,
                headsign: transit.headsign,
                minutes: 2
            )
        }
    }

    private func cancelScheduledNotifications() {
        if !scheduledNotificationIds.isEmpty {
            NotificationManager.shared.cancel(ids: scheduledNotificationIds)
            scheduledNotificationIds.removeAll()
        }
    }

    // MARK: - Utilities

    private func departureDate(for itinerary: TripItinerary) -> Date {
        // Scheduled boarding time = itinerary.departureDate + walk-to-stop seconds.
        // We already computed that as `TransitLeg.departureTime` — rebuild the
        // absolute Date here using TripPlanner's helper.
        guard let transit = itinerary.transitLegs.first else { return Date() }
        return TripPlanner.absoluteDate(for: transit.departureTime, reference: itinerary.departureDate)
    }

    private func walkLegBefore(transit: TransitLeg, in itinerary: TripItinerary) -> WalkLeg? {
        guard let idx = itinerary.legs.firstIndex(where: {
            if case .transit(let t) = $0 { return t.id == transit.id } else { return false }
        }), idx > 0 else { return nil }
        if case .walk(let w) = itinerary.legs[idx - 1] { return w }
        return nil
    }

    private func minutesFromNow(_ timeString: String) -> Int {
        let parts = timeString.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return -1 }
        let cal = Calendar.current
        let now = Date()
        let curH = cal.component(.hour, from: now)
        let curM = cal.component(.minute, from: now)
        var dep = (h % 24) * 60 + m
        let cur = curH * 60 + curM
        if dep < cur { dep += 24 * 60 }
        return dep - cur
    }

    private func minuteLabel(_ minutes: Int) -> String {
        switch minutes {
        case ...0:  return String(localized: "live.imminent")
        case 1:     return String(localized: "live.one_minute")
        default:    return String(format: String(localized: "live.n_minutes"), minutes)
        }
    }

    private func goStatusLabel(minutes: Int, walkMinutes: Int) -> String {
        if minutes <= 0 { return String(localized: "live.imminent") }
        if walkMinutes > 0 && minutes <= walkMinutes {
            return String(format: String(localized: "live.leave_now"), walkMinutes)
        }
        return String(format: String(localized: "live.n_minutes"), minutes)
    }
}

// MARK: - Track button view

struct TrackDepartureButton: View {
    let entry: ScheduleEntry
    let stop: Stop
    @ObservedObject var manager: LiveActivityManager

    private var isCurrentlyTracking: Bool { manager.isTracking(entry: entry) }
    private var minutes: Int {
        let parts = entry.departureTime.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return -1 }
        let cal = Calendar.current
        let now = Date()
        var dep = (h % 24) * 60 + m
        let cur = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        if dep < cur { dep += 24 * 60 }
        return dep - cur
    }

    var body: some View {
        if minutes >= 0 && minutes <= 60 {
            Button {
                if isCurrentlyTracking {
                    manager.stopTracking()
                } else {
                    manager.startTracking(entry: entry, stop: stop)
                }
            } label: {
                Label(
                    isCurrentlyTracking ? "Arrêter le suivi" : "Suivre ce départ",
                    systemImage: isCurrentlyTracking ? "bell.slash" : "bell.badge.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isCurrentlyTracking ? .secondary : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isCurrentlyTracking ? Color(.systemFill) : (Color(hex: entry.routeColor) ?? .blue),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: isCurrentlyTracking)
        }
    }
}
