import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Timeline entry

struct NextDeparturesEntry: TimelineEntry {
    let date: Date
    let snapshot: DepartureSnapshot?
}

// MARK: - Provider

struct NextDeparturesProvider: TimelineProvider {

    func placeholder(in context: Context) -> NextDeparturesEntry {
        NextDeparturesEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextDeparturesEntry) -> Void) {
        let snap = SharedDataStore.loadSnapshots().first ?? .placeholder
        completion(NextDeparturesEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextDeparturesEntry>) -> Void) {
        let snaps = SharedDataStore.loadSnapshots()
        let snap  = snaps.first
        let entry = NextDeparturesEntry(date: Date(), snapshot: snap)

        // Refresh every 10 minutes
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 10, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }
}

// MARK: - Widget view

struct NextDeparturesWidgetView: View {
    var entry: NextDeparturesProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall:  SmallWidget(snapshot: snapshot)
            case .systemMedium: MediumWidget(snapshot: snapshot)
            case .accessoryRectangular: AccessoryWidget(snapshot: snapshot)
            default:            MediumWidget(snapshot: snapshot)
            }
        } else {
            emptyWidget
        }
    }

    private var emptyWidget: some View {
        VStack {
            Image(systemName: "tram.circle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Ajoutez un favori\ndans l'app")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill, for: .widget)
    }
}

// MARK: - Small widget (1 stop, 3 departures)

struct SmallWidget: View {
    let snapshot: DepartureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "tram.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(snapshot.stopName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            ForEach(snapshot.entries.prefix(3)) { entry in
                HStack(spacing: 6) {
                    Text(entry.routeShortName)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(entry.color, in: RoundedRectangle(cornerRadius: 3))

                    Text(minuteLabel(entry.minutesFromNow))
                        .font(.caption)
                        .foregroundStyle(entry.minutesFromNow <= 2 ? .orange : .primary)
                    Spacer()
                }
            }

            if snapshot.entries.isEmpty {
                Text("Aucun départ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .containerBackground(.fill, for: .widget)
    }
}

// MARK: - Medium widget (stop name + 4 departures with headsign)

struct MediumWidget: View {
    let snapshot: DepartureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "tram.circle.fill")
                    .foregroundStyle(.blue)
                Text(snapshot.stopName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(snapshot.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            ForEach(snapshot.entries.prefix(4)) { entry in
                HStack(spacing: 8) {
                    Text(entry.routeShortName)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 34)
                        .padding(.vertical, 2)
                        .background(entry.color, in: RoundedRectangle(cornerRadius: 4))

                    Text(entry.headsign)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(minuteLabel(entry.minutesFromNow))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.minutesFromNow <= 2 ? .orange : .primary)
                }
            }
        }
        .padding(12)
        .containerBackground(.fill, for: .widget)
    }
}

// MARK: - Lock Screen accessory widget

struct AccessoryWidget: View {
    let snapshot: DepartureSnapshot

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(snapshot.stopName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                if let first = snapshot.entries.first {
                    Text("\(first.routeShortName) · \(minuteLabel(first.minutesFromNow))")
                        .font(.caption2)
                }
            }
            Spacer()
        }
        .containerBackground(.fill, for: .widget)
    }
}

// MARK: - Helpers

private func minuteLabel(_ minutes: Int) -> String {
    if minutes <= 0 { return "Maintenant" }
    if minutes == 1 { return "1 min" }
    return "\(minutes) min"
}

// MARK: - Placeholder

extension DepartureSnapshot {
    static let placeholder = DepartureSnapshot(
        id: "placeholder",
        stopName: "Station Guy-Concordia",
        updatedAt: Date(),
        entries: [
            SnapshotEntry(id: "1", minutesFromNow: 2,  routeShortName: "Verte", headsign: "Angrignon",  routeColor: "008000"),
            SnapshotEntry(id: "2", minutesFromNow: 7,  routeShortName: "Verte", headsign: "Honoré-Beaugrand", routeColor: "008000"),
            SnapshotEntry(id: "3", minutesFromNow: 15, routeShortName: "15",    headsign: "Sainte-Catherine", routeColor: "F47922"),
        ]
    )
}

// MARK: - Main widget declaration

struct NextDeparturesWidget: Widget {
    let kind = "NextDeparturesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextDeparturesProvider()) { entry in
            NextDeparturesWidgetView(entry: entry)
        }
        .configurationDisplayName("Prochains départs")
        .description("Affiche les prochains départs de votre arrêt favori.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - Live Activity widget

struct TransitHubLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DepartureAttributes.self) { context in
            // Lock Screen / Notification banner
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RouteTag(shortName: context.attributes.routeShortName,
                             colorHex: context.attributes.routeColor)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MinutesBadge(minutes: context.state.minutesUntilDeparture,
                                 isDelayed: context.state.isDelayed)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.headsign)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Image(systemName: "mappin.circle")
                        Text(context.attributes.stopName)
                        Spacer()
                        Text(context.state.statusMessage)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                RouteTag(shortName: context.attributes.routeShortName,
                         colorHex: context.attributes.routeColor)
            } compactTrailing: {
                MinutesBadge(minutes: context.state.minutesUntilDeparture,
                             isDelayed: context.state.isDelayed)
            } minimal: {
                MinutesBadge(minutes: context.state.minutesUntilDeparture,
                             isDelayed: context.state.isDelayed)
            }
        }
    }
}

// MARK: - Live Activity views

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<DepartureAttributes>

    var routeColor: Color {
        Color(hex: context.attributes.routeColor) ?? .blue
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(routeColor)
                    .frame(width: 48, height: 36)
                Text(context.attributes.routeShortName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.headsign)
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Image(systemName: "mappin.circle")
                        .font(.caption2)
                    Text(context.attributes.stopName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if context.state.minutesUntilDeparture <= 0 {
                    Text("Maintenant")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                } else {
                    Text("\(context.state.minutesUntilDeparture)")
                        .font(.title2.bold())
                        .foregroundStyle(context.state.isDelayed ? .red : .primary)
                    Text("min").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .activityBackgroundTint(Color(.systemBackground))
    }
}

struct RouteTag: View {
    let shortName: String
    let colorHex: String

    var body: some View {
        Text(shortName)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color(hex: colorHex) ?? .blue, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct MinutesBadge: View {
    let minutes: Int
    let isDelayed: Bool

    var body: some View {
        if minutes <= 0 {
            Text("!")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        } else {
            Text("\(minutes)'")
                .font(.caption.bold())
                .foregroundStyle(isDelayed ? .red : .primary)
        }
    }
}
