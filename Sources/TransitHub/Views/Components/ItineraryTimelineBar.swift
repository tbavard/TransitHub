import SwiftUI

// MARK: - Itinerary timeline (Transit-style "frise horaire")
//
// Every result is drawn on the same time axis: line pills sit where the
// vehicle is actually boarded and last as long as the ride, with a dotted
// baseline for the walking and waiting in between. Comparing options is then a
// matter of looking at where each one starts and ends.

enum ItineraryTimeline {

    /// One stretch of an itinerary on the time axis.
    struct Segment: Identifiable {
        let id: UUID
        let start: Date
        let end: Date
        /// Set for rides; nil for walks.
        let transit: TransitLeg?
    }

    /// The itinerary's legs placed in time. A ride starts at its (live-adjusted)
    /// boarding time, but never before the previous leg ended; any gap is the
    /// wait at the stop.
    static func segments(for itinerary: TripItinerary) -> [Segment] {
        var cursor = itinerary.departureDate
        var result: [Segment] = []
        for leg in itinerary.legs {
            switch leg {
            case .walk(let walk):
                let end = cursor.addingTimeInterval(Double(walk.walkMinutes) * 60)
                result.append(Segment(id: walk.id, start: cursor, end: end, transit: nil))
                cursor = end
            case .transit(let transit):
                let boarding = transit.scheduledDeparture
                    .map { $0.addingTimeInterval(Double(transit.liveDelaySeconds ?? 0)) } ?? cursor
                let start = max(cursor, boarding)
                let end = start.addingTimeInterval(Double(max(transit.onboardMinutes, 1)) * 60)
                result.append(Segment(id: transit.id, start: start, end: end, transit: transit))
                cursor = end
            }
        }
        return result
    }

    /// The time range that fits every itinerary (nil when there is nothing to draw).
    static func axis(for itineraries: [TripItinerary]) -> (start: Date, end: Date)? {
        guard let start = itineraries.map(\.departureDate).min(),
              let end = itineraries.map(\.arrivalDate).max(),
              end > start else { return nil }
        return (start, end)
    }
}

struct ItineraryTimelineBar: View {
    let itinerary: TripItinerary
    let axisStart: Date
    let axisEnd: Date

    private static let minPillWidth: CGFloat = 44
    private static let height: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let total = max(axisEnd.timeIntervalSince(axisStart), 1)
            let width = geo.size.width
            let xPos: (Date) -> CGFloat = { date in
                CGFloat(date.timeIntervalSince(axisStart) / total) * width
            }
            let segments = ItineraryTimeline.segments(for: itinerary)

            ZStack(alignment: .leading) {
                // Dotted baseline: walking and waiting between the rides.
                if let first = segments.first, let last = segments.last {
                    Capsule()
                        .fill(Color(.systemGray4))
                        .frame(width: max(xPos(last.end) - xPos(first.start), 0), height: 4)
                        .offset(x: xPos(first.start))
                }

                ForEach(segments) { segment in
                    if let transit = segment.transit {
                        let pillWidth = max(xPos(segment.end) - xPos(segment.start), Self.minPillWidth)
                        let x = min(max(xPos(segment.start), 0), max(width - pillWidth, 0))
                        pill(for: transit, width: pillWidth)
                            .offset(x: x)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
    }

    private func pill(for transit: TransitLeg, width: CGFloat) -> some View {
        let tint = Color(hex: transit.routeColor) ?? Theme.brandStart
        return Text(transit.routeShortName)
            .font(Typography.pill)
            .foregroundStyle(tint.readableForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width, height: Self.height)
            .background(tint.livelyGradient, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .shadow(color: tint.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}
