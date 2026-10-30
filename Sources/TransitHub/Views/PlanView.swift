import SwiftUI
import CoreLocation

// MARK: - Picker role

enum PlanPickerRole {
    case origin, destination
}

// MARK: - Plan view
//
// One network at a time: the user picks the network (only shown when more than
// one is installed), then a destination — the search runs by itself whenever
// the destination, origin, network or time changes.

struct PlanView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore

    @AppStorage("plan.providerId") private var storedProviderId = ""

    @State private var origin: PlanEndpoint = .userLocation
    @State private var destination: PlanEndpoint? = nil

    @State private var departAt: Date = Date()
    @State private var useNow: Bool = true

    @State private var itineraries: [TripItinerary] = []
    @State private var isPlanning = false
    @State private var planError: String?

    @State private var pickerRole: PlanPickerRole? = nil

    /// The network being planned on: the stored choice, else the first one.
    private var provider: TransitProvider? {
        providersStore.providers.first { $0.id == storedProviderId }
            ?? providersStore.providers.first
    }

    /// Everything a search depends on; the search re-runs when it changes.
    private struct PlanRequest: Equatable {
        let origin: PlanEndpoint
        let destination: PlanEndpoint
        let providerId: String
        let useNow: Bool
        let departMinute: Int
    }

    private var request: PlanRequest? {
        guard let destination, let provider else { return nil }
        return PlanRequest(
            origin: origin,
            destination: destination,
            providerId: provider.id,
            useNow: useNow,
            departMinute: useNow ? 0 : Int(departAt.timeIntervalSince1970 / 60))
    }

    var body: some View {
        NavigationStack {
            Group {
                if providersStore.providers.isEmpty {
                    NoProvidersView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            if providersStore.providers.count > 1 { networkMenu }
                            endpointsCard
                            timeRow
                            content
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.xxxl)
                    }
                    .background(Theme.screenBackground)
                    .refreshable { await plan() }
                }
            }
            .navigationTitle("Itinéraire")
            .task(id: request) { await plan() }
            .onAppear { consumePending(appVM.pendingPlanDestination) }
            .onChange(of: appVM.pendingPlanDestination) { _, stop in consumePending(stop) }
            // Success / error tap when a search finishes.
            .sensoryFeedback(trigger: isPlanning) { wasPlanning, planning in
                guard wasPlanning, !planning else { return nil }
                return planError == nil ? .success : .error
            }
            .sheet(item: $pickerRole) { role in
                PlanStopPickerView(providerId: provider?.id ?? "") { endpoint in
                    switch role {
                    case .origin:      origin = endpoint
                    case .destination: destination = endpoint
                    }
                    itineraries = []
                    planError = nil
                }
            }
        }
    }

    // MARK: - Network

    private var networkMenu: some View {
        Menu {
            ForEach(providersStore.providers) { p in
                Button {
                    select(p)
                } label: {
                    if p.id == provider?.id {
                        Label(p.fullName, systemImage: "checkmark")
                    } else {
                        Text(p.fullName)
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.s) {
                if let p = provider {
                    ProviderBadge(provider: p)
                    Text(p.fullName)
                        .font(Typography.body.weight(.medium))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.sm)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .accessibilityLabel(Text("Réseau"))
    }

    /// "Y aller" on a stop: plan from the user's position to that stop.
    private func consumePending(_ stop: Stop?) {
        guard let stop else { return }
        storedProviderId = stop.providerId
        origin = .userLocation
        destination = .stop(stop)
        itineraries = []
        planError = nil
        appVM.pendingPlanDestination = nil
    }

    /// Switching network invalidates both endpoints (they belong to the old one).
    private func select(_ p: TransitProvider) {
        guard p.id != provider?.id else { return }
        storedProviderId = p.id
        origin = .userLocation
        destination = nil
        itineraries = []
        planError = nil
    }

    // MARK: - Endpoints

    private var endpointsCard: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                endpointRow(label: "De", icon: "circle.fill", iconColor: Theme.brandStart,
                            endpoint: origin) {
                    pickerRole = .origin
                }
                Divider().padding(.leading, 48)
                endpointRow(label: "À", icon: "mappin.circle.fill", iconColor: Theme.statusCritical,
                            endpoint: destination) {
                    pickerRole = .destination
                }
            }
            .card()

            Button { swapEndpoints() } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(Spacing.m)
                    .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                    .overlay(Circle().strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .minTouchTarget()
            }
            .buttonStyle(.plain)
            .padding(.trailing, Spacing.md)
            .disabled(destination == nil)
            .accessibilityLabel(Text("Inverser départ et destination"))
        }
    }

    @ViewBuilder
    private func endpointRow(
        label: String,
        icon: String,
        iconColor: Color,
        endpoint: PlanEndpoint?,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(label)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let ep = endpoint {
                        Text(ep.displayName)
                            .font(Typography.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text("Choisir un lieu")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(Spacing.lg)
            // Leave room for the swap button.
            .padding(.trailing, Spacing.xxxl + Spacing.md)
        }
        .buttonStyle(.plain)
    }

    private func swapEndpoints() {
        guard let dest = destination else { return }
        let newDest = origin
        origin = dest
        destination = newDest
        itineraries = []
        planError = nil
    }

    // MARK: - Time

    private var timeRow: some View {
        HStack(spacing: Spacing.sm) {
            Menu {
                Button("Partir maintenant") { useNow = true }
                Button("Choisir l'heure…") {
                    departAt = Date()
                    useNow = false
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    (useNow ? Text("Partir maintenant") : Text("Partir à…"))
                        .font(Typography.body.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.sm)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }

            if !useNow {
                DatePicker("Heure de départ", selection: $departAt,
                           displayedComponents: [.hourAndMinute, .date])
                    .labelsHidden()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Content (empty / loading / error / results)

    @ViewBuilder
    private var content: some View {
        if destination == nil {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                    .scaledIcon(44)
                    .foregroundStyle(Theme.brandStart)
                    .accessibilityHidden(true)
                Text("Où allez-vous ?")
                    .font(Typography.sectionTitle)
                Text("Choisissez une destination : les prochains départs s'affichent automatiquement.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xxxl)
        } else if let err = planError {
            errorCard(err)
        } else if isPlanning && itineraries.isEmpty {
            ProgressView("Recherche…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xxxl)
        } else {
            VStack(spacing: Spacing.m) {
                ForEach(itineraries) { itin in
                    ItineraryCard(itin: itin)
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Theme.statusWarning)
                .accessibilityHidden(true)
            Text(message)
                .font(Typography.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Spacing.lg)
        .background(Theme.statusWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Theme.statusWarning.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Plan action

    private func plan() async {
        guard let destination, let provider else {
            itineraries = []
            planError = nil
            isPlanning = false
            return
        }
        isPlanning = true
        planError = nil
        let start = useNow ? Date() : departAt
        do {
            let result = try await appVM.planTrip(
                from: origin, to: destination, providerId: provider.id, departAt: start)
            // A newer request replaced this one: let it publish its own result.
            if Task.isCancelled { return }
            itineraries = result
            if result.isEmpty {
                planError = TripPlanError.noRouteFound.errorDescription
            }
        } catch is CancellationError {
            return
        } catch let err as TripPlanError {
            if Task.isCancelled { return }
            itineraries = []
            planError = err.errorDescription
        } catch {
            if Task.isCancelled { return }
            itineraries = []
            planError = error.localizedDescription
        }
        isPlanning = false
    }
}

// MARK: - Picker role Identifiable

extension PlanPickerRole: Identifiable {
    var id: String {
        switch self {
        case .origin:      return "origin"
        case .destination: return "destination"
        }
    }
}

// MARK: - Itinerary card

struct ItineraryCard: View {
    @EnvironmentObject var liveActivityManager: LiveActivityManager
    let itin: TripItinerary

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()

    private var isTracked: Bool { liveActivityManager.isTracking(itinerary: itin) }
    private var canGo: Bool { itin.departureDate.timeIntervalSinceNow > -60 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            Divider()
            legStrip
            if !itin.transitLegs.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(itin.transitLegs) { t in
                        Text(summary(for: t))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if canGo { goButton }
        }
        .padding(Spacing.lg)
        .background(Theme.cardBackground,
                    in: RoundedRectangle(cornerRadius: Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl)
                .strokeBorder(isTracked ? Theme.brandStart.opacity(0.5)
                                        : Color(.separator).opacity(0.25),
                              lineWidth: isTracked ? 1.5 : 0.5)
        )
        .trackingFeedback(isTracked)
    }

    private var goButton: some View {
        Button {
            if isTracked {
                liveActivityManager.stopTracking()
            } else {
                liveActivityManager.startTracking(itinerary: itin)
            }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: isTracked ? "bell.slash.fill" : "paperplane.fill")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
                Text(isTracked ? "Arrêter le suivi" : "Partir")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.m)
            .background(isTracked ? AnyShapeStyle(Color(.systemFill)) : AnyShapeStyle(Theme.brandGradient),
                        in: Capsule())
            .foregroundStyle(isTracked ? Color.primary : .white)
        }
        .buttonStyle(.plain)
        .motionSafe(.easeInOut(duration: 0.2), value: isTracked)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    Text(Self.timeFmt.string(from: itin.departureDate))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(Self.timeFmt.string(from: itin.arrivalDate))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                HStack(spacing: Spacing.s) {
                    Text("Durée : \(itin.totalMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    (itin.transitLegs.count > 1 ? Text("1 correspondance") : Text("Direct"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let delay = itin.transitLegs.first?.liveDelaySeconds {
                        liveBadge(delayMinutes: Int((Double(delay) / 60).rounded()))
                    }
                }
            }
            Spacer()
        }
    }

    /// Times above already include the live delay; this says so.
    private func liveBadge(delayMinutes m: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            LiveIndicator()
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
            .foregroundStyle(m >= 1 ? Theme.soonText : Theme.urgentText)
        }
    }

    /// Walk and route pills in order, e.g. 🚶3 min · [55] · 🚶1 min · [10] · 🚶4 min.
    private var legStrip: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(Array(itin.legs.enumerated()), id: \.offset) { _, leg in
                switch leg {
                case .walk(let w):
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "figure.walk")
                            .font(.caption2.weight(.bold))
                            .accessibilityHidden(true)
                        Text("\(w.walkMinutes) min")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                case .transit(let t):
                    RoutePill(shortName: t.routeShortName, color: t.routeColor)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func summary(for t: TransitLeg) -> String {
        let count = t.numStops - 1
        let stopsText = count == 1 ? String(localized: "1 arrêt") : String(localized: "\(count) arrêts")
        return "\(t.fromStop.name) → \(t.toStop.name) · \(stopsText)"
    }
}
