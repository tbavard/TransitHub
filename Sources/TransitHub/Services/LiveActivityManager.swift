import Foundation
import ActivityKit
import SwiftUI
import os

/// Whether a transfer can still be made given the live times.
enum ConnectionCheck {
    /// Margin kept on top of the walk between the two stops.
    static let slackSeconds = 30

    static func isAtRisk(arrival: Date, walkSeconds: Int, nextBoarding: Date) -> Bool {
        arrival.addingTimeInterval(TimeInterval(walkSeconds + slackSeconds)) > nextBoarding
    }
}

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
        let routeColor: String
        let headsign: String
        let walkMinutes: Int            // > 0 only for the first leg of an itinerary
        let notificationKey: String
    }

    /// The hop between two rides of a one-transfer itinerary: where the first
    /// ride ends and how long the walk to the next stop takes.
    private struct Connection {
        let alightStopId: String
        let alightStopName: String
        let alightSequence: Int?
        let scheduledArrival: Date      // timetable time, never shifted
        let walkSeconds: Int
        let notificationKey: String
    }

    /// The leg being counted down (the first ride, then the second one).
    private var tracked: TrackedDeparture?
    /// The ride after the current one, and the connection leading to it.
    private var followingLeg: TrackedDeparture?
    private var connection: Connection?

    /// Latest live delay at the boarding stop (seconds, 0 = on time/unknown).
    private var liveDelaySeconds = 0
    /// Latest live delay at the stop where the current ride ends.
    private var arrivalDelaySeconds = 0
    /// Latest live delay at the following ride's boarding stop.
    private var followingDelaySeconds = 0
    private var isCanceled = false
    /// The live times no longer leave time to make the connection.
    private var connectionAtRisk = false

    /// Boarding time the countdown runs against: timetable + live delay.
    private var currentBoardingDate: Date? {
        tracked.map { $0.scheduledBoarding.addingTimeInterval(TimeInterval(liveDelaySeconds)) }
    }

    private var liveArrivalAtConnection: Date? {
        connection.map { $0.scheduledArrival.addingTimeInterval(TimeInterval(arrivalDelaySeconds)) }
    }

    private var followingBoardingDate: Date? {
        followingLeg.map { $0.scheduledBoarding.addingTimeInterval(TimeInterval(followingDelaySeconds)) }
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
                routeColor:        entry.routeColor,
                headsign:          entry.headsign,
                walkMinutes:       0,
                notificationKey:   entry.tripId
            ),
            following: nil,
            connection: nil,
            initialDelay: entry.delaySeconds ?? 0
        )
        activeEntry = entry
        trackedItineraryId = nil
    }

    // MARK: - Track a planned itinerary (Go mode)

    /// Starts Go mode for a planned itinerary. The Live Activity counts down to
    /// the first ride's boarding time, then switches to the second ride once
    /// the first one has been boarded. Notifications fire when it's time to
    /// leave, when the vehicle is approaching, when to get off for the
    /// transfer, and if live delays put the connection at risk.
    func startTracking(itinerary: TripItinerary) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let rides = itinerary.transitLegs
        guard let first = rides.first else { return }

        let firstLeg = trackedDeparture(for: first, in: itinerary,
                                        walkMinutes: walkLegBefore(transit: first, in: itinerary)?.walkMinutes ?? 0)

        var followingLeg: TrackedDeparture?
        var connection: Connection?
        if rides.count > 1 {
            let second = rides[1]
            followingLeg = trackedDeparture(for: second, in: itinerary, walkMinutes: 0)
            connection = Connection(
                alightStopId:     first.toStop.id,
                alightStopName:   first.toStop.name,
                alightSequence:   first.fromStopSequence.map { $0 + max(first.numStops - 1, 0) },
                scheduledArrival: firstLeg.scheduledBoarding
                    .addingTimeInterval(Double(max(first.onboardMinutes, 1)) * 60),
                walkSeconds:      Int((walkLegBetween(first, second, in: itinerary)?.walkMinutes ?? 0) * 60),
                notificationKey:  itinerary.id.uuidString
            )
        }

        begin(firstLeg, following: followingLeg, connection: connection,
              initialDelay: first.liveDelaySeconds ?? 0,
              initialFollowingDelay: rides.count > 1 ? (rides[1].liveDelaySeconds ?? 0) : 0)
        activeEntry = nil
        trackedItineraryId = itinerary.id
    }

    private func trackedDeparture(for transit: TransitLeg, in itinerary: TripItinerary,
                                  walkMinutes: Int) -> TrackedDeparture {
        // Planner-resolved timetable boarding time (handles previous-day
        // overnight trips); legacy fallback re-derives it from the string.
        let scheduled = transit.scheduledDeparture
            ?? TripPlanner.absoluteDate(for: transit.departureTime, reference: itinerary.departureDate)
        return TrackedDeparture(
            providerId:        transit.providerId,
            tripId:            transit.tripId,
            stopId:            transit.fromStop.id,
            stopSequence:      transit.fromStopSequence,
            scheduledBoarding: scheduled,
            stopName:          transit.fromStop.name,
            routeShortName:    transit.routeShortName,
            routeColor:        transit.routeColor,
            headsign:          transit.headsign,
            walkMinutes:       walkMinutes,
            notificationKey:   "\(itinerary.id.uuidString)-\(transit.id.uuidString)"
        )
    }

    private func begin(_ target: TrackedDeparture,
                       following: TrackedDeparture?,
                       connection: Connection?,
                       initialDelay: Int,
                       initialFollowingDelay: Int = 0) {
        // Only one activity at a time.
        cancelScheduledNotifications()
        updateTask?.cancel()

        tracked = target
        followingLeg = following
        self.connection = connection
        liveDelaySeconds = initialDelay
        arrivalDelaySeconds = initialDelay
        followingDelaySeconds = initialFollowingDelay
        isCanceled = false
        connectionAtRisk = false
        guard let boarding = currentBoardingDate else { return }

        let attrs = DepartureAttributes(
            routeShortName: target.routeShortName,
            routeColor:     target.routeColor,
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
            followingLeg = nil
            self.connection = nil
            logger.error("Live Activity error: \(String(describing: error))")
        }
    }

    // MARK: - Realtime

    /// Feeds the latest GTFS-RT trip updates (called by MainTabView after each
    /// realtime refresh). Moves the countdown with the live delay, flags a
    /// cancellation, reschedules notifications when a time shifts by a minute
    /// or more, and warns when the delays make the transfer impossible.
    func applyRealtime(_ tripUpdatesByProvider: [String: [String: TripUpdate]]) {
        guard isTracking, let target = tracked else { return }
        let updates = tripUpdatesByProvider[target.providerId] ?? [:]

        let previousDelay = liveDelaySeconds
        let previousArrivalDelay = arrivalDelaySeconds

        let status = RealtimeScheduleMerger.status(
            tripId:       target.tripId,
            stopId:       target.stopId,
            stopSequence: target.stopSequence,
            scheduled:    target.scheduledBoarding,
            updates:      updates
        )
        switch status {
        case .delay(let seconds)?:
            liveDelaySeconds = seconds
            isCanceled = false
        case .canceled?, .skipped?:
            isCanceled = true
        case nil:
            break   // no news: keep the last known prediction
        }

        // The ride's end and the next ride's start, for the transfer.
        if let conn = connection {
            let alighting = RealtimeScheduleMerger.status(
                tripId:       target.tripId,
                stopId:       conn.alightStopId,
                stopSequence: conn.alightSequence,
                scheduled:    conn.scheduledArrival,
                updates:      updates
            )
            if case .delay(let seconds)? = alighting {
                arrivalDelaySeconds = seconds
            } else {
                arrivalDelaySeconds = liveDelaySeconds   // delay carries down the line
            }
        }
        if let next = followingLeg {
            let boarding = RealtimeScheduleMerger.status(
                tripId:       next.tripId,
                stopId:       next.stopId,
                stopSequence: next.stopSequence,
                scheduled:    next.scheduledBoarding,
                updates:      tripUpdatesByProvider[next.providerId] ?? [:]
            )
            if case .delay(let seconds)? = boarding { followingDelaySeconds = seconds }
        }
        checkConnection()

        if isCanceled {
            cancelScheduledNotifications()
        } else if abs(liveDelaySeconds - previousDelay) >= 60
                    || abs(arrivalDelaySeconds - previousArrivalDelay) >= 60 {
            cancelScheduledNotifications()
            scheduleNotifications()
        }
        refreshNow()
    }

    /// Notifies once when the first ride now reaches the transfer stop too late
    /// to walk and board the second one; re-arms if things recover.
    private func checkConnection() {
        guard let conn = connection, let next = followingLeg,
              let arrival = liveArrivalAtConnection,
              let boarding = followingBoardingDate,
              let target = tracked else { connectionAtRisk = false; return }

        let atRisk = ConnectionCheck.isAtRisk(arrival: arrival, walkSeconds: conn.walkSeconds, nextBoarding: boarding)
        if atRisk && !connectionAtRisk {
            let id = "connection-\(conn.notificationKey)"
            scheduledNotificationIds.append(id)
            Task {
                await NotificationManager.shared.notifyConnectionAtRisk(
                    id: id,
                    fromRoute: target.routeShortName,
                    arrival: arrival,
                    toRoute: next.routeShortName,
                    departure: boarding
                )
            }
        }
        connectionAtRisk = atRisk
    }

    // MARK: - ScenePhase hook

    /// Pushes fresh content to the Live Activity. Called every 30 s by the
    /// update loop, after realtime updates, and when the app returns to the
    /// foreground so the countdown never shows stale minutes.
    func refreshNow() {
        guard isTracking, let boarding = currentBoardingDate else { return }
        // A couple of minutes past boarding the user is either on the vehicle
        // or missed it: move on to the second ride of a transfer, or end.
        if boarding.timeIntervalSinceNow < -2 * 60 {
            if advanceToFollowingLeg() { return }
            stopTracking()
            return
        }
        pushState()
    }

    /// Switches the countdown to the second ride once the first was boarded.
    private func advanceToFollowingLeg() -> Bool {
        guard let next = followingLeg else { return false }
        cancelScheduledNotifications()
        tracked = next
        followingLeg = nil
        connection = nil
        liveDelaySeconds = followingDelaySeconds
        arrivalDelaySeconds = followingDelaySeconds
        followingDelaySeconds = 0
        isCanceled = false
        connectionAtRisk = false
        scheduleNotifications()
        pushState()
        return true
    }

    private func pushState() {
        let state = currentState()
        let stale = currentBoardingDate?.addingTimeInterval(5 * 60)
        Task { [weak self] in
            await self?.activity?.update(ActivityContent(state: state, staleDate: stale))
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
            followingLeg = nil
            connection = nil
            liveDelaySeconds = 0
            arrivalDelaySeconds = 0
            followingDelaySeconds = 0
            isCanceled = false
            connectionAtRisk = false
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
        } else if connectionAtRisk {
            label = String(localized: "live.connection_at_risk")
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
            isDelayed:             isCanceled || connectionAtRisk || delayMinutes >= 1,
            statusMessage:         label,
            // The activity's static attributes describe the first ride; these
            // let the second ride take over the same activity.
            routeShortName:        tracked?.routeShortName,
            routeColor:            tracked?.routeColor,
            headsign:              tracked?.headsign,
            stopName:              tracked?.stopName
        )
    }

    /// "Time to leave" (first leg of an itinerary), "approaching", and — before
    /// a transfer — "get off" notifications, all anchored on live times.
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

        // One minute before the first ride reaches the transfer stop.
        if let conn = connection, let next = followingLeg, let arrival = liveArrivalAtConnection {
            let alightId = "alight-\(conn.notificationKey)"
            scheduledNotificationIds.append(alightId)
            Task {
                await NotificationManager.shared.scheduleAlight(
                    id: alightId,
                    fireDate: arrival.addingTimeInterval(-60),
                    stopName: conn.alightStopName,
                    nextRouteShortName: next.routeShortName
                )
            }
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

    /// The walk between two consecutive rides, if the stops differ.
    private func walkLegBetween(_ first: TransitLeg, _ second: TransitLeg,
                                in itinerary: TripItinerary) -> WalkLeg? {
        walkLegBefore(transit: second, in: itinerary)
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
