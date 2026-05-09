import SwiftUI
import CoreLocation

// MARK: - Picker role

enum PlanPickerRole {
    case origin, destination
}

// MARK: - Plan view

struct PlanView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore

    @State private var origin: PlanEndpoint = .userLocation
    @State private var destination: PlanEndpoint? = nil

    @State private var departAt: Date = Date()
    @State private var useNow: Bool = true

    @State private var itineraries: [TripItinerary] = []
    @State private var isPlanning = false
    @State private var planError: String?

    @State private var pickerRole: PlanPickerRole? = nil

    var body: some View {
        NavigationStack {
            Group {
                if providersStore.providers.isEmpty {
                    NoProvidersView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            endpointsCard
                            timeCard
                            planButton
                            resultsSection
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Itinéraire")
            .sheet(item: $pickerRole) { role in
                PlanStopPickerView { endpoint in
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

    // MARK: - Endpoints

    private var endpointsCard: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                endpointRow(label: "De", icon: "circle.fill", iconColor: .blue,
                            endpoint: origin) {
                    pickerRole = .origin
                }
                Divider().padding(.leading, 48)
                endpointRow(label: "À", icon: "mappin.circle.fill", iconColor: .red,
                            endpoint: destination) {
                    pickerRole = .destination
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))

            Button { swapEndpoints() } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                    .overlay(Circle().strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .disabled(destination == nil)
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
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let ep = endpoint {
                        Text(ep.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text("Choisir un lieu")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
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

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $useNow) {
                Text("Partir maintenant").tag(true)
                Text("Partir à…").tag(false)
            }
            .pickerStyle(.segmented)

            if !useNow {
                DatePicker("Heure de départ", selection: $departAt,
                           displayedComponents: [.hourAndMinute, .date])
                    .datePickerStyle(.compact)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Plan button

    private var planButton: some View {
        Button {
            Task { await plan() }
        } label: {
            HStack(spacing: 8) {
                if isPlanning {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                }
                Text(isPlanning ? "Recherche…" : "Trouver un itinéraire")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isReadyToPlan ? Color.accentColor : Color(.systemGray3),
                        in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!isReadyToPlan || isPlanning)
    }

    private var isReadyToPlan: Bool { destination != nil }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if let err = planError {
            errorCard(err)
        } else if !itineraries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(itineraries.count) itinéraire(s)")
                    .font(.headline)
                VStack(spacing: 10) {
                    ForEach(itineraries) { itin in
                        ItineraryCard(itin: itin)
                    }
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Plan action

    private func plan() async {
        guard let destination else { return }
        isPlanning = true
        planError = nil
        itineraries = []
        let start = useNow ? Date() : departAt
        do {
            itineraries = try await appVM.planTrip(from: origin, to: destination, departAt: start)
            if itineraries.isEmpty {
                planError = TripPlanError.noRouteFound.errorDescription
            }
        } catch let err as TripPlanError {
            planError = err.errorDescription
        } catch {
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
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            legStrip
            if let summary = summaryLine {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if canGo { goButton }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isTracked ? Color.accentColor.opacity(0.5)
                                        : Color(.separator).opacity(0.25),
                              lineWidth: isTracked ? 1.5 : 0.5)
        )
    }

    private var goButton: some View {
        Button {
            if isTracked {
                liveActivityManager.stopTracking()
            } else {
                liveActivityManager.startTracking(itinerary: itin)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isTracked ? "bell.slash.fill" : "paperplane.fill")
                    .font(.caption.weight(.bold))
                Text(isTracked ? "Arrêter le suivi" : "Partir")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isTracked ? Color(.systemFill) : Color.accentColor,
                        in: Capsule())
            .foregroundStyle(isTracked ? Color.primary : .white)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isTracked)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.timeFmt.string(from: itin.departureDate))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(Self.timeFmt.string(from: itin.arrivalDate))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                Text("Durée : \(itin.totalMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let t = itin.transitLegs.first {
                RoutePill(shortName: t.routeShortName, color: t.routeColor)
            }
        }
    }

    private var legStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(itin.legs.enumerated()), id: \.offset) { _, leg in
                switch leg {
                case .walk(let w):
                    HStack(spacing: 3) {
                        Image(systemName: "figure.walk")
                            .font(.caption2.weight(.bold))
                        Text("\(w.walkMinutes) min")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                case .transit(let t):
                    HStack(spacing: 3) {
                        Image(systemName: "bus.fill")
                            .font(.caption2.weight(.bold))
                        Text(t.headsign.isEmpty ? t.routeShortName : t.headsign)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color(hex: t.routeColor) ?? .primary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var summaryLine: String? {
        guard let t = itin.transitLegs.first else { return nil }
        let stopsWord = t.numStops - 1 == 1 ? "arrêt" : "arrêts"
        return "\(t.fromStop.name) → \(t.toStop.name) · \(t.numStops - 1) \(stopsWord)"
    }
}
