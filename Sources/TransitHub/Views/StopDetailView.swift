import SwiftUI
import MapKit
import CoreLocation
import ActivityKit

struct StopDetailView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var liveActivityManager: LiveActivityManager
    let stop: Stop
    /// Set when the stop was opened from a route's detail: the screen then
    /// shows only that line/direction, with an opt-in to see every line.
    var routeContext: StopRouteContext? = nil

    @State private var schedule: [ScheduleEntry] = []
    @State private var isLoading = true
    @State private var error: Error?
    @State private var now = Date()
    @State private var showAllRoutes = false

    private var isFavorite: Bool { appVM.isFavorite(stop) }

    /// The route context actually applied (nil once the user picks "all lines").
    private var activeContext: StopRouteContext? {
        showAllRoutes ? nil : routeContext
    }

    private var displayedSchedule: [ScheduleEntry] {
        appVM.withRealtime(schedule, at: stop).filtered(for: activeContext)
    }

    /// True when this stop is served by lines other than the context route —
    /// only then is the "this line / all lines" picker worth showing.
    private var servesOtherRoutes: Bool {
        guard let ctx = routeContext else { return false }
        return schedule.contains { $0.routeId != ctx.route.gtfsId }
    }

    // Alerts that mention this stop directly, or affect a route displayed here.
    private var stopAlerts: [ServiceAlert] {
        var routeIds = Set(displayedSchedule.map { $0.routeId })
        if let ctx = activeContext { routeIds.insert(ctx.route.gtfsId) }
        return appVM.serviceAlerts.filter { alert in
            alert.affectedStopCodes.contains(stop.id) ||
            alert.affectedRouteIds.contains { routeIds.contains($0) }
        }
    }

    // One section per route AND direction, sorted naturally by route number.
    private var departureGroups: [StopDepartureGroup] {
        displayedSchedule.groupedByRouteAndDirection()
    }

    private var emptyScheduleDescription: Text {
        // Most specific reason first: the network's timetable hasn't started.
        if schedule.isEmpty, let notice = appVM.serviceNotStartedMessage(for: stop.providerId) {
            return Text(verbatim: notice)
        }
        if let ctx = activeContext {
            return Text("Aucun service actif pour la ligne \(ctx.route.shortName) à cet arrêt.")
        }
        return Text("Aucun service actif pour cet arrêt.")
    }

    private func nextEntry(for entries: [ScheduleEntry]) -> ScheduleEntry? {
        entries.first { !$0.hasDepartedToday && !$0.isCanceled } ?? entries.first
    }

    /// The two departures right after `next`, for the "then in…" chips.
    private func following(_ next: ScheduleEntry, in entries: [ScheduleEntry]) -> [ScheduleEntry] {
        guard !next.hasDepartedToday else { return [] }
        return Array(entries.drop(while: { $0.id != next.id }).dropFirst()
            .filter { !$0.isCanceled }.prefix(2))
    }

    // Walking information: "350 m · 4 min"
    private var walkingInfo: String? {
        guard let loc = appVM.userLocation else { return nil }
        let dist = stop.distance(from: loc)
        let walkMin = max(1, Int((dist / 80).rounded()))  // ~80 m/min walking
        return "\(stop.formattedDistance(from: loc)) · \(walkMin) min"
    }

    private var stopIcon: String { stop.isStation ? "tram.fill" : "bus.fill" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl, pinnedViews: .sectionHeaders) {
                stopHeaderCard
                    .padding(.horizontal, Spacing.xl)

                if servesOtherRoutes, let ctx = routeContext {
                    routeScopePicker(ctx)
                        .padding(.horizontal, Spacing.xl)
                }

                if !stopAlerts.isEmpty {
                    stopAlertsSection
                }

                if isLoading {
                    skeletonSections
                } else if let err = error {
                    ContentUnavailableView {
                        Label("Erreur", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err.localizedDescription)
                    } actions: {
                        Button("Réessayer") { Task { await loadSchedule() } }
                    }
                    .frame(minHeight: 300)
                } else if displayedSchedule.isEmpty {
                    ContentUnavailableView(
                        "Aucun départ aujourd'hui",
                        systemImage: "clock.badge.xmark",
                        description: emptyScheduleDescription
                    )
                    .frame(minHeight: 300)
                } else {
                    ForEach(departureGroups) { group in
                        Section {
                            routeSectionBody(group: group)
                        } header: {
                            routeHeader(for: group)
                        }
                    }
                }

                locationCard
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .background(Theme.screenBackground)
        .navigationTitle(stop.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadSchedule() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await loadSchedule() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityLabel(Text("Actualiser"))
                }
            }
        }
        .task { await loadSchedule() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { t in
            now = t
        }
    }

    // MARK: - Header card (identity + actions)

    private var stopHeaderCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: stopIcon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: Radius.lg))
                    .shadow(color: Theme.brandStart.opacity(0.3), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(stop.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                    HStack(spacing: Spacing.s) {
                        ProviderBadge(providerId: stop.providerId)
                        Text(stop.isStation ? "Station" : "Arrêt")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        Text("·").font(Typography.caption).foregroundStyle(.tertiary)
                        Text("#\(stop.id)")
                            .font(Typography.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let info = walkingInfo {
                Label(info, systemImage: "figure.walk")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.brandStart)
                    .tintedCapsule(Theme.brandStart)
            }

            actionBar
        }
        .padding(Spacing.lg)
        .card()
        .favoriteFeedback(isFavorite)
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.sm) {
            StopActionButton(
                icon: isFavorite ? "star.fill" : "star",
                label: isFavorite ? "Favori" : "Favoriser",
                tint: isFavorite ? Theme.favorite : Theme.brandStart
            ) {
                withAnimation(.spring(duration: 0.25)) {
                    appVM.toggleFavorite(stop)
                }
            }

            StopActionButton(
                icon: "figure.walk",
                label: "Itinéraire",
                tint: Theme.brandStart
            ) {
                openInMaps()
            }

            ShareLink(
                item: String(localized: "\(stop.name) — arrêt #\(stop.id)"),
                subject: Text(stop.name)
            ) {
                StopActionLabel(icon: "square.and.arrow.up", label: "Partager", tint: Theme.brandStart)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Location card (map at the bottom: the schedule comes first)

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Localisation", icon: "map.fill", color: Theme.brandStart)
            mapSnippet
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 2)
        }
    }

    private var mapSnippet: some View {
        Button { openInMaps() } label: {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: stop.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            ))) {
                UserAnnotation()
                Annotation("", coordinate: stop.coordinate, anchor: .bottom) {
                    Image(systemName: stopIcon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Theme.brandGradient, in: Circle())
                        .shadow(color: Theme.brandStart.opacity(0.4), radius: 3, x: 0, y: 1)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Route header

    /// Section header; tapping it opens the route — except for the route the
    /// user just came from, where "back" already does that.
    @ViewBuilder
    private func routeHeader(for group: StopDepartureGroup) -> some View {
        let header = RouteScheduleHeader(
            routeShortName: group.routeShortName,
            headsign: group.headsign,
            color: group.routeColor,
            showsDisclosure: linkedRoute(for: group) != nil
        )
        if let route = linkedRoute(for: group) {
            NavigationLink(value: AppDestination.route(route)) { header }
                .buttonStyle(.plain)
        } else {
            header
        }
    }

    private func linkedRoute(for group: StopDepartureGroup) -> Route? {
        guard group.routeId != routeContext?.route.gtfsId else { return nil }
        return appVM.routes.first {
            $0.gtfsId == group.routeId && $0.providerId == stop.providerId
        }
    }

    // MARK: - Route scope picker

    private func routeScopePicker(_ ctx: StopRouteContext) -> some View {
        Picker("Lignes affichées", selection: $showAllRoutes.animation(.snappy)) {
            Text("Ligne \(ctx.route.shortName)").tag(false)
            Text("Toutes les lignes").tag(true)
        }
        .pickerStyle(.segmented)
        .selectionFeedback(showAllRoutes)
    }

    // MARK: - Alerts

    @ViewBuilder
    private var stopAlertsSection: some View {
        VStack(spacing: Spacing.s) {
            ForEach(stopAlerts) { alert in
                let color = alert.severityColor
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: alert.effectIcon)
                        .font(.subheadline)
                        .foregroundStyle(color)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(alert.typeLabel)
                            .font(Typography.caption.weight(.semibold))
                            .foregroundStyle(color)
                            .tintedCapsule(color)
                        Text(alert.title)
                            .font(Typography.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if !alert.body.isEmpty {
                            Text(alert.body)
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.m)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(color.opacity(0.2), lineWidth: 1))
            }
        }
        .padding(.horizontal, Spacing.xl)
    }

    // MARK: - Per-route section

    @ViewBuilder
    private func routeSectionBody(group: StopDepartureGroup) -> some View {
        let next = nextEntry(for: group.entries)
        let tint = Color(hex: group.routeColor) ?? Theme.brandStart

        VStack(alignment: .leading, spacing: Spacing.md) {
            if let next {
                NextDepartureHero(
                    entry: next,
                    following: following(next, in: group.entries),
                    now: now
                )
                TrackDepartureButton(entry: next, stop: stop, manager: liveActivityManager)
            }
            ScheduleGrid(entries: group.entries, nextEntry: next, tint: tint)
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Skeleton

    private var skeletonSections: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(spacing: Spacing.m) {
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .fill(Color(.systemFill))
                            .frame(width: 44, height: 28)
                        RoundedRectangle(cornerRadius: Radius.xs)
                            .fill(Color(.systemFill))
                            .frame(width: 140, height: 14)
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: Radius.xl)
                        .fill(Color(.systemFill))
                        .frame(height: 96)
                    RoundedRectangle(cornerRadius: Radius.xl)
                        .fill(Color(.systemFill))
                        .frame(height: 80)
                }
                .padding(.horizontal, Spacing.xl)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: - Actions

    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: stop.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = stop.name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    // MARK: - Data loading

    private func loadSchedule() async {
        // Skeleton only on first load; refreshes keep the current content.
        isLoading = schedule.isEmpty
        error = nil
        do {
            schedule = try await appVM.fetchSchedule(for: stop)
        } catch {
            self.error = error
        }
        isLoading = false
    }
}

// MARK: - Stop action button

private struct StopActionButton: View {
    let icon: String
    let label: LocalizedStringKey
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StopActionLabel(icon: icon, label: label, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

private struct StopActionLabel: View {
    let icon: String
    let label: LocalizedStringKey
    let tint: Color

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .symbolEffect(.bounce, value: icon)   // e.g. star filling in
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

// MARK: - Next departure hero
//
// The headline of each route section: big countdown on the route's own
// gradient, headsign, and the next two departures as chips.

struct NextDepartureHero: View {
    let entry: ScheduleEntry
    let following: [ScheduleEntry]
    /// Not read directly: changing it every minute re-renders the countdown.
    let now: Date

    private var minutes: Int { entry.minutesUntilDeparture }
    private var isPast: Bool { entry.hasDepartedToday }

    private var tint: Color {
        isPast || entry.isCanceled
            ? Color(.systemGray)
            : (Color(hex: entry.routeColor) ?? Theme.brandStart)
    }

    private var countdownText: String {
        if entry.isCanceled { return String(localized: "Annulé") }
        if isPast           { return entry.displayTime }
        if minutes == 0     { return String(localized: "countdown.imminent") }
        if minutes < 60     { return "\(minutes) min" }
        return entry.predictedDisplayTime
    }

    private static func shortCountdown(_ e: ScheduleEntry) -> String {
        let m = e.minutesUntilDeparture
        return m < 60 ? "\(m) min" : e.predictedDisplayTime
    }

    /// "En direct · +3 min" style badge; nothing for schedule-only data.
    @ViewBuilder
    private func realtimeBadge(fg: Color) -> some View {
        if entry.delaySeconds != nil {
            let m = entry.delayMinutes
            HStack(spacing: Spacing.xs) {
                LiveIndicator(color: fg)
                Group {
                    if m >= 1 {
                        Text("Retard \(m) min")
                    } else if m <= -1 {
                        Text("Avance \(-m) min")
                    } else {
                        Text("À l'heure")
                    }
                }
                .font(Typography.badge)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(fg.opacity(0.18), in: Capsule())
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    /// Whole card read as one sentence, e.g. "next departure, line 24,
    /// towards Est, in 4 minutes, at 08:14, live, 2 minutes late, then 12 min".
    private var accessibilitySummary: String {
        A11y.join([
            String(localized: isPast ? "a11y.no_more" : "a11y.next"),
            A11y.route(entry.routeShortName),
            A11y.towards(entry.headsign),
            entry.isCanceled ? nil : A11y.countdown(minutes),
            String(format: String(localized: "a11y.at_time"), entry.predictedDisplayTime),
            A11y.liveStatus(of: entry),
            following.isEmpty ? nil : String(format: String(localized: "a11y.then"),
                                             A11y.countdowns(following.map { $0.minutesUntilDeparture }))
        ])
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var content: some View {
        let fg = tint.readableForeground
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.s) {
                        Text(isPast ? "Plus de départ aujourd'hui" : "Prochain départ")
                            .font(Typography.caption.weight(.semibold))
                            .opacity(0.85)
                        realtimeBadge(fg: fg)
                    }
                    Text(countdownText)
                        .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: Spacing.sm)
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    if !isPast && !entry.isCanceled && minutes < 60 {
                        Text(entry.predictedDisplayTime)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                    }
                    // Timetable time, struck through when the live
                    // prediction differs from it.
                    if entry.delayMinutes != 0 || entry.isCanceled {
                        Text(entry.displayTime)
                            .font(Typography.caption.weight(.medium))
                            .monospacedDigit()
                            .strikethrough()
                            .opacity(0.75)
                    }
                    Label(entry.headsign, systemImage: "arrow.right")
                        .font(Typography.caption.weight(.medium))
                        .lineLimit(1)
                        .opacity(0.9)
                }
            }

            if !following.isEmpty {
                HStack(spacing: Spacing.s) {
                    Text("Puis")
                        .font(Typography.caption)
                        .opacity(0.85)
                    ForEach(following) { e in
                        Text(Self.shortCountdown(e))
                            .font(Typography.caption.weight(.bold))
                            .monospacedDigit()
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(fg.opacity(0.18), in: Capsule())
                    }
                }
            }
        }
        .foregroundStyle(fg)
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.livelyGradient, in: RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: tint.opacity(0.35), radius: 10, x: 0, y: 6)
        .animation(.snappy, value: countdownText)
        .animation(.snappy, value: entry.realtime)
        .imminentFeedback(!isPast && !entry.isCanceled && minutes == 0)
    }
}

// MARK: - Route schedule header (uses shared RoutePill)

struct RouteScheduleHeader: View {
    let routeShortName: String
    let headsign: String
    let color: String
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            RoutePill(shortName: routeShortName, color: color)
                .frame(width: 48)
            Text(headsign)
                .font(Typography.body.weight(.semibold))
                .lineLimit(1)
            Spacer()
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Schedule grid

struct ScheduleGrid: View {
    let entries: [ScheduleEntry]
    let nextEntry: ScheduleEntry?
    var tint: Color = Theme.brandStart

    // Keyed by the raw GTFS hour (0…27+) so tonight's after-midnight trips
    // ("24:15") sort at the bottom instead of merging into this morning's 00h
    // row; the label wraps to 24h.
    private var byHour: [(hour: Int, entries: [ScheduleEntry])] {
        let groups = Dictionary(grouping: entries) { entry -> Int in
            Int(entry.departureTime.split(separator: ":").first ?? "") ?? 0
        }
        return groups.sorted { $0.key < $1.key }
            .map { (hour: $0.key, entries: $0.value.sorted { $0.departureTime < $1.departureTime }) }
    }

    private var visibleHours: [(hour: Int, entries: [ScheduleEntry])] {
        let all = byHour
        guard let firstUpcoming = all.firstIndex(where: { row in
            row.entries.contains { !$0.hasDepartedToday }
        }) else { return all }
        let start = max(0, firstUpcoming - 1)
        return Array(all[start...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(visibleHours, id: \.hour) { row in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Text(String(format: "%02dh", row.hour % 24))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                        // minWidth (not width) so large Dynamic Type doesn't truncate.
                        .frame(minWidth: 36, alignment: .leading)
                        .fixedSize()
                        .padding(.top, 3)
                        // Each chip already speaks its full time.
                        .accessibilityHidden(true)

                    FlowLayout(spacing: 5) {
                        ForEach(row.entries) { entry in
                            MinuteChip(
                                entry: entry,
                                isNext: entry.id == nextEntry?.id,
                                tint: tint
                            )
                        }
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
    }
}

// MARK: - Minute chip

struct MinuteChip: View {
    let entry: ScheduleEntry
    let isNext: Bool
    var tint: Color = Theme.brandStart

    private var minuteStr: String {
        let parts = entry.departureTime.split(separator: ":")
        guard parts.count >= 2, let m = Int(parts[1]) else { return "--" }
        return String(format: "%02d", m)
    }

    private var background: AnyShapeStyle {
        if isNext { return AnyShapeStyle(tint.livelyGradient) }
        return AnyShapeStyle(Color(.systemFill).opacity(entry.hasDepartedToday ? 0.5 : 1))
    }

    var body: some View {
        Text(minuteStr)
            .font(.system(isNext ? .body : .callout, design: .monospaced)
                .weight(isNext ? .bold : .regular))
            .strikethrough(entry.isCanceled)
            .foregroundStyle(
                isNext ? tint.readableForeground :
                entry.hasDepartedToday || entry.isCanceled ? Color(.tertiaryLabel) : .primary
            )
            .padding(.horizontal, isNext ? Spacing.m : 7)
            .padding(.vertical,   isNext ? Spacing.s : 3)
            .background(background, in: RoundedRectangle(cornerRadius: isNext ? Radius.sm : 5))
            // Timetable grid keeps scheduled minutes; a dot flags runs the
            // live feed reports as late.
            .overlay(alignment: .topTrailing) {
                if entry.delayMinutes >= 2 && !entry.hasDepartedToday {
                    Circle()
                        .fill(Theme.soon)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -2)
                }
            }
            .shadow(color: isNext ? tint.opacity(0.35) : .clear, radius: 4, x: 0, y: 2)
            .scaleEffect(isNext ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isNext)
            // "08:14, next departure" / "07:52, departed" / "09:05, canceled".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11y.join([
                entry.displayTime,
                isNext ? String(localized: "a11y.next") : nil,
                entry.isCanceled ? String(localized: "a11y.canceled")
                    : entry.hasDepartedToday ? String(localized: "a11y.departed")
                    : nil,
                entry.delayMinutes >= 2 && !entry.isCanceled
                    ? String(format: String(localized: "a11y.late"), entry.delayMinutes) : nil
            ]))
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                x = 0; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
