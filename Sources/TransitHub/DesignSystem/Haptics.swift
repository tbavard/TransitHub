import SwiftUI

// MARK: - Haptics
//
// One vocabulary for tactile feedback (iOS 17 `sensoryFeedback`), so the same
// action feels the same everywhere. Each modifier fires only when its trigger
// value changes — never on first appearance.

extension View {
    /// Favorite added → success tap; removed → light tap.
    func favoriteFeedback(_ isFavorite: Bool) -> some View {
        sensoryFeedback(trigger: isFavorite) { _, added in
            added ? .success : .impact(weight: .light)
        }
    }

    /// Live Activity / Go mode started or stopped.
    func trackingFeedback(_ isTracking: Bool) -> some View {
        sensoryFeedback(trigger: isTracking) { _, started in
            started ? .start : .stop
        }
    }

    /// Discrete choice changed (direction, line scope…).
    func selectionFeedback<T: Equatable>(_ value: T) -> some View {
        sensoryFeedback(.selection, trigger: value)
    }

    /// A departure just became imminent while on screen.
    func imminentFeedback(_ isImminent: Bool) -> some View {
        sensoryFeedback(trigger: isImminent) { wasImminent, nowImminent in
            !wasImminent && nowImminent ? .impact(weight: .medium) : nil
        }
    }
}
