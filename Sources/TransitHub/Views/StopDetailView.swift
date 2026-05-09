import SwiftUI
import MapKit
import CoreLocation
import ActivityKit

struct StopDetailView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var liveActivityManager: LiveActivityManager
    let stop: Stop

    @State private var schedule: [ScheduleEntry] = []
    @State private var isLoading = true
    @State private var error: Error?
    @State private var now = Date()

    private var isFavorite: Bool { appVM.isFavorite(stop) }

    // Alerts that mention this stop directly, or affect a route that serves it.
    private var stopAlerts: [ServiceAlert] {
        let routeIds = Set(schedule.map { $0.routeId })
        return appVM.serviceAlerts.filter { alert in
            alert.affectedStopCodes.contains(stop.id) ||
            !alert.affectedRouteIds.filter { routeIds.contains($0) }.isEmpty
        }
    }

    // Grouped by route short name, sorted by departure time within each group.
    private var groupedByRoute: [(key: String, entries: [ScheduleEntry])] {
        let groups = Dictionary(grouping: schedule) { $0.routeShortName }
        return groups.sorted { lhs, rhs in
            let lInt = Int(lhs.key), rInt = Int(rhs.key)
            switch (lInt, rInt) {
            case (nil, nil): return lhs.key < rhs.key
            case (nil, _):   return true
            case (_, nil):   return false
            default:         return lInt! < rInt!
            }
        }
        .map { (key: $0.key, entries: $0.value.sorted { $0.departureTime < $1.departureTime }) }
    }

    private func nextEntry(for entries: [ScheduleEntry]) -> ScheduleEntry? {
        entries.first { !$0.hasDepartedToday } ?? entries.first
    }

    // Walking information: "350 m · 4 min"
    private var walkingInfo: String? {
        guard let loc = appVM.userLocation else { return nil }
        let dist = stop.distance(from: loc)
        let walkMin = max(1, Int((dist / 80).rounded()))  // ~80 m/min walking
        return "\(stop.formattedDistance(from: loc)) · \(walkMin) min"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                stopHeaderCard
                    .padding(.horizontal, 16)

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
                } else if schedule.isEmpty {
                    ContentUnavailableView(
                        "Aucun départ aujourd'hui",
                        systemImage: "clock.badge.xmark",
                        description: Text("Aucun service actif pour cet arrêt.")
                    )
                    .frame(minHeight: 300)
                } else {
                    ForEach(groupedByRoute, id: \.key) { group in
                        Section {
                            routeSectionBody(group: group)
                        } header: {
                            RouteScheduleHeader(
                                routeShortName: group.key,
                                headsign: group.entries.first?.headsign ?? "",
                                color: group.entries.first?.routeColor ?? ""
                            )
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(stop.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadSchedule() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await loadSchedule() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await loadSchedule() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { t in
            now = t
        }
    }

    // MARK: - Header card (map + info + actions)

    private var stopHeaderCard: some View {
        VStack(spacing: 0) {
            mapSnippet
                .frame(height: 140)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 16, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 16
                ))
                .overlay(alignment: .topTrailing) {
                    if let info = walkingInfo {
                        HStack(spacing: 4) {
                            Image(systemName: "figure.walk")
                                .font(.caption2.weight(.bold))
                            Text(info)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                        .foregroundStyle(.secondary)
                    Text(stop.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                    Spacer(minLength: 4)
                }

                HStack(spacing: 6) {
                    ProviderBadge(providerId: stop.providerId)
                    Text(stop.isStation ? "Station de métro" : "Arrêt d'autobus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text("#\(stop.id)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }

                actionBar
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    private var mapSnippet: some View {
        Button { openInMaps() } label: {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: stop.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            ))) {
                UserAnnotation()
                Annotation("", coordinate: stop.coordinate, anchor: .bottom) {
                    ZStack {
                        Circle()
                            .fill(stop.isStation ? Color.blue : Color.accentColor)
                            .frame(width: 28, height: 28)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            StopActionButton(
                icon: isFavorite ? "star.fill" : "star",
                label: isFavorite ? "Favori" : "Favoriser",
                tint: isFavorite ? .yellow : .accentColor
            ) {
                withAnimation(.spring(duration: 0.25)) {
                    appVM.toggleFavorite(stop)
                }
            }

            StopActionButton(
                icon: "figure.walk",
                label: "Itinéraire",
                tint: .accentColor
            ) {
                openInMaps()
            }

            ShareLink(
                item: "\(stop.name) — arrêt #\(stop.id)",
                subject: Text(stop.name)
            ) {
                StopActionLabel(icon: "square.and.arrow.up", label: "Partager", tint: .accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Alerts

    @ViewBuilder
    private var stopAlertsSection: some View {
        VStack(spacing: 6) {
            ForEach(stopAlerts) { alert in
                let color = alert.severityColor
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: alert.effectIcon)
                        .font(.subheadline)
                        .foregroundStyle(color)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.typeLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(color.opacity(0.12), in: Capsule())
                        Text(alert.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if !alert.body.isEmpty {
                            Text(alert.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.2), lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Per-route section

    @ViewBuilder
    private func routeSectionBody(group: (key: String, entries: [ScheduleEntry])) -> some View {
        let next = nextEntry(for: group.entries)

        VStack(alignment: .leading, spacing: 10) {
            if let next {
                NextDepartureBanner(stop: stop, entry: next, now: now)
                TrackDepartureButton(entry: next, stop: stop, manager: liveActivityManager)
            }
            ScheduleGrid(entries: group.entries, nextEntry: next)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Skeleton

    private var skeletonSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemFill))
                            .frame(width: 44, height: 28)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemFill))
                            .frame(width: 140, height: 14)
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.systemFill))
                        .frame(height: 66)
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(.systemFill))
                                .frame(width: 28, height: 26)
                        }
                    }
                }
                .padding(.horizontal, 16)
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
        isLoading = true
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
    let label: String
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
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Next Departure Banner

struct NextDepartureBanner: View {
    let stop: Stop
    let entry: ScheduleEntry
    let now: Date

    private var minutes: Int { entry.minutesUntilDeparture }
    private var isPast: Bool  { entry.hasDepartedToday }

    private var countdownText: String {
        if isPast       { return entry.displayTime }
        if minutes == 0 { return String(localized: "countdown.imminent") }
        if minutes < 60 { return String(format: String(localized: "countdown.minutes"), minutes) }
        return entry.displayTime
    }

    private var urgencyColor: Color {
        if isPast       { return .secondary }
        if minutes == 0 { return .green }
        if minutes <= 5 { return .orange }
        return .primary
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(urgencyColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: stop.isStation ? "tram.fill" : "bus.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(urgencyColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Prochain départ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(countdownText)
                    .font(.title3.bold())
                    .foregroundStyle(urgencyColor)
                    .contentTransition(.numericText())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if !isPast && minutes < 60 {
                    Text(entry.displayTime)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text(entry.headsign)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.3), value: countdownText)
    }
}

// MARK: - Route schedule header (uses shared RoutePill)

struct RouteScheduleHeader: View {
    let routeShortName: String
    let headsign: String
    let color: String

    var body: some View {
        HStack(spacing: 10) {
            RoutePill(shortName: routeShortName, color: color)
                .frame(width: 48)
            Text(headsign)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Schedule grid

struct ScheduleGrid: View {
    let entries: [ScheduleEntry]
    let nextEntry: ScheduleEntry?

    private var byHour: [(hour: String, entries: [ScheduleEntry])] {
        let groups = Dictionary(grouping: entries) { entry -> String in
            let parts = entry.departureTime.split(separator: ":")
            guard let h = Int(parts.first ?? "0") else { return "00" }
            return String(format: "%02d", h % 24)
        }
        return groups.sorted { $0.key < $1.key }
            .map { (hour: $0.key, entries: $0.value.sorted { $0.departureTime < $1.departureTime }) }
    }

    private var visibleHours: [(hour: String, entries: [ScheduleEntry])] {
        let all = byHour
        guard let firstUpcoming = all.firstIndex(where: { row in
            row.entries.contains { !$0.hasDepartedToday }
        }) else { return all }
        let start = max(0, firstUpcoming - 1)
        return Array(all[start...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleHours, id: \.hour) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.hour + "h")
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                        .padding(.top, 3)

                    FlowLayout(spacing: 5) {
                        ForEach(row.entries) { entry in
                            MinuteChip(
                                entry: entry,
                                isNext: entry.id == nextEntry?.id
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Minute chip

struct MinuteChip: View {
    let entry: ScheduleEntry
    let isNext: Bool

    private var minuteStr: String {
        let parts = entry.departureTime.split(separator: ":")
        guard parts.count >= 2, let m = Int(parts[1]) else { return "--" }
        return String(format: "%02d", m)
    }

    var body: some View {
        Text(minuteStr)
            .font(.system(isNext ? .body : .callout, design: .monospaced)
                .weight(isNext ? .bold : .regular))
            .foregroundStyle(
                isNext ? .white :
                entry.hasDepartedToday ? Color(.tertiaryLabel) : .primary
            )
            .padding(.horizontal, isNext ? 10 : 7)
            .padding(.vertical,   isNext ?  6 : 3)
            .background(
                isNext ? Color.accentColor :
                entry.hasDepartedToday ? Color(.systemFill).opacity(0.5) : Color(.systemFill),
                in: RoundedRectangle(cornerRadius: isNext ? 8 : 5)
            )
            .scaleEffect(isNext ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isNext)
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
