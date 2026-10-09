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

    /// What is being tracked, independent of the flow (single departure or
    /// itinerary): enough to re-match GTFS-RT updates and to reschedule the
    /// notifications when the live boarding time moves.
    private struct TrackedDeparture {
        let providerId: String
        let tripId: String
        let stopId: String
        let stopSequence: Int?
        let scheduledBoarding: Date     // timetable time, never shifted
        let stopName: String
        let routeShortName: String
        let headsign: String
        let walkMinutes: Int            // > 0 only in itinerary (Go) mode
        let notificationKey: String
    }

    private var tracked: TrackedDeparture?
    /// Latest live delay at the boarding stop (seconds, 0 = on time/unknown).
    private var liveDelaySeconds = 0
    private var isCanceled = false

    /// Boarding time the countdown runs against: timetable + live delay.
    private var currentBoardingDate: Date? {
        tracked.map { $0.scheduledBoarding.addingTimeInterval(TimeInterval(liveDelaySeconds)) }
    }

    private let logger = Logger(subsystem: "com.transithub", category: "LiveActivity")

    // MARK: - Track a single stop departure

    /// `entry` may already carry a realtime status (it comes from the stop
    /// screen, which merges live data); its delay seeds the countdown.
    func startTracking(entry: ScheduleEntry, stop: Stop) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard !entry.hasDepartedToday, !entry.isCanceled,
              let scheduled = RealtimeScheduleMerger.scheduledDate(
                  of: entry, midnight: Calendar.current.startOfDay(for: Date()))
        else { return }

        begin(
            TrackedDeparture(
                providerId:        stop.providerId,
                tripId:            entry.tripId,
                stopId:            stop.id,
                stopSequence:      entry.stopSequence,
                scheduledBoarding: scheduled,
                stopName:          stop.name,
                routeShortName:    entry.routeShortName,
                headsign:          entry.headsign,
                walkMinutes:       0,
                notificationKey:   entry.tripId
            ),
            routeColor: entry.routeColor,
            initialDelay: entry.delaySeconds ?? 0
        )
        activeEntry = entry
        trackedItineraryId = nil
    }

    // MARK: - Track a planned itinerary (Go mode)

    /// Starts Go mode for a planned itinerary. Live Activity tracks the first
    /// transit leg's boarding time; notifications fire when it's time to leave
    /// and when the vehicle is approaching.
    func startTracking(itinerary: TripItinerary) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let transit = itinerary.transitLegs.first else { return }

        // Planner-resolved timetable boarding time (handles previous-day
        // overnight trips); legacy fallback re-derives it from the string.
        let scheduled = transit.scheduledDeparture
            ?? TripPlanner.absoluteDate(for: transit.departureTime, reference: itinerary.departureDate)

        begin(
            TrackedDeparture(
                providerId:        transit.providerId,
                tripId:            transit.tripId,
                stopId:            transit.fromStop.id,
                stopSequence:      transit.fromStopSequence,
                scheduledBoarding: scheduled,
                stopName:          transit.fromStop.name,
                routeShortName:    transit.routeShortName,
                headsign:          transit.headsign,
                walkMinutes:       walkLegBefore(transit: transit, in: itinerary)?.walkMinutes ?? 0,
                notificationKey:   itinerary.id.uuidString
            ),
            routeColor: transit.routeColor,
            initialDelay: transit.liveDelaySeconds ?? 0
        )
        activeEntry = nil
        trackedItineraryId = itinerary.id
    }

    private func begin(_ target: TrackedDeparture, routeColor: String, initialDelay: Int) {
        // Only one activity at a time.
        cancelScheduledNotifications()
        updateTask?.cancel()

        tracked = target
        liveDelaySeconds = initialDelay
        isCanceled = false
        guard let boarding = currentBoardingDate else { return }

        let attrs = DepartureAttributes(
            routeShortName: target.routeShortName,
            routeColor:     routeColor,
            headsign:       target.headsign,
            stopName:       target.stopName
        )
        do {
            activity = try Activity.request(
                attributes: attrs,
                content: ActivityContent(state: currentState(), staleDate: boarding.addingTimeInterval(5 * 60)),
                pushType: nil
            )
            isTracking = true
            scheduleNotifications()
            startUpdateLoop()
        } catch {
            tracked = nil
            logger.error("Live Activity error: \(String(describing: error))")
        }
    }

    // MARK: - Realtime

    /// Feeds the latest GTFS-RT trip updates (called by MainTabView after each
    /// realtime refresh). Moves the countdown with the live delay, flags a
    /// cancellation, and reschedules notifications when boarding shifts by
    /// a minute or more.
    func applyRealtime(_ tripUpdatesByProvider: [String: [String: TripUpdate]]) {
        guard isTracking, let target = tracked else { return }
        let status = RealtimeScheduleMerger.status(
            tripId:       target.tripId,
            stopId:       target.stopId,
            stopSequence: target.stopSequence,
            scheduled:    target.scheduledBoarding,
            updates:      tripUpdatesByProvider[target.providerId] ?? [:]
        )
        let previousDelay = liveDelaySeconds
        switch status {
        case .delay(let seconds)?:
            liveDelaySeconds = seconds
            isCanceled = false
        case .canceled?, .skipped?:
            isCanceled = true
        case nil:
            break   // no news: keep the last known prediction
        }
        if isCanceled {
            cancelScheduledNotifications()
        } else if abs(liveDelaySeconds - previousDelay) >= 60 {
            cancelScheduledNotifications()
            scheduleNotifications()
        }
        refreshNow()
    }

    // MARK: - ScenePhase hook

    /// Pushes fresh content to the Live Activity. Called every 30 s by the
    /// update loop, after realtime updates, and when the app returns to the
    /// foreground so the countdown never shows stale minutes.
    func refreshNow() {
        guard isTracking, let boarding = currentBoardingDate else { return }
        // End a couple of minutes past boarding — by then the user is either
        // on the vehicle or missed it.
        if boarding.timeIntervalSinceNow < -2 * 60 {
            stopTracking()
            return
        }
        let state = currentState()
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
            tracked = nil
            liveDelaySeconds = 0
            isCanceled = false
        }
    }

    // MARK: - Queries

    func isTracking(entry: ScheduleEntry) -> Bool {
        isTracking && activeEntry?.tripId == entry.tripId
    }

    func isTracking(itinerary: TripItinerary) -> Bool {
        isTracking && trackedItineraryId == itinerary.id
    }

    // MARK: - Private helpers

    private func startUpdateLoop() {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                refreshNow()
            }
        }
    }

    private func currentState() -> DepartureAttributes.ContentState {
        let boarding = currentBoardingDate ?? Date()
        let mins = max(0, Int(boarding.timeIntervalSinceNow / 60))
        let delayMinutes = Int((Double(liveDelaySeconds) / 60).rounded())

        let label: String
        if isCanceled {
            label = String(localized: "live.canceled")
        } else {
            let base = (tracked?.walkMinutes ?? 0) > 0
                ? goStatusLabel(minutes: mins, walkMinutes: tracked?.walkMinutes ?? 0)
                : minuteLabel(mins)
            label = delayMinutes >= 1
                ? String(format: String(localized: "live.delayed_suffix"), base, delayMinutes)
                : base
        }
        return DepartureAttributes.ContentState(
            minutesUntilDeparture: mins,
            isDelayed:             isCanceled || delayMinutes >= 1,
            statusMessage:         label
        )
    }

    /// "Time to leave" (Go mode only) and "approaching" notifications, both
    /// anchored on the live boarding time.
    private func scheduleNotifications() {
        guard let target = tracked, let boarding = currentBoardingDate else { return }

        if target.walkMinutes > 0 {
            let leaveId = "leave-\(target.notificationKey)"
            scheduledNotificationIds.append(leaveId)
            Task {
                await NotificationManager.shared.scheduleTimeToLeave(
                    id: leaveId,
                    fireDate: boarding.addingTimeInterval(-TimeInterval(target.walkMinutes * 60)),
                    stopName: target.stopName,
                    routeShortName: target.routeShortName,
                    walkMinutes: target.walkMinutes
                )
            }
        }

        let approachingId = "approach-\(target.notificationKey)"
        scheduledNotificationIds.append(approachingId)
        Task {
            await NotificationManager.shared.scheduleVehicleApproaching(
                id: approachingId,
                fireDate: boarding.addingTimeInterval(-2 * 60),
                stopName: target.stopName,
                routeShortName: target.routeShortName,
                headsign: target.headsign,
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

    private func walkLegBefore(transit: TransitLeg, in itinerary: TripItinerary) -> WalkLeg? {
        guard let idx = itinerary.legs.firstIndex(where: {
            if case .transit(let t) = $0 { return t.id == transit.id } else { return false }
        }), idx > 0 else { return nil }
        if case .walk(let w) = itinerary.legs[idx - 1] { return w }
        return nil
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
    // Same source of truth as the rest of the stop screen (handles GTFS
    // times ≥ 24:00 correctly, unlike the former local `h % 24` math).
    private var minutes: Int { entry.minutesUntilDeparture }
    private var tint: Color { Color(hex: entry.routeColor) ?? Theme.brandStart }

    var body: some View {
        if minutes >= 0 && minutes <= 60 && !entry.isCanceled {
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
                .foregroundStyle(isCurrentlyTracking ? Color.secondary : tint.readableForeground)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.s)
                .background(
                    isCurrentlyTracking ? AnyShapeStyle(Color(.systemFill)) : AnyShapeStyle(tint.livelyGradient),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: isCurrentlyTracking)
            .trackingFeedback(isCurrentlyTracking)
        }
    }
}
