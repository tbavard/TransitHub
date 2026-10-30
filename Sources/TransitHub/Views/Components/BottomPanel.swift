import SwiftUI

// MARK: - Bottom panel
//
// A draggable panel docked to the bottom of its container with three resting
// heights, like the Google Maps / Apple Maps sheets. Unlike `.sheet` it lives
// inside the screen, so the tab bar stays reachable and the map behind keeps
// responding to touches outside the panel.
//
// Behaviour (same idea as Apple Maps):
// - collapsed / half: the content does not scroll; dragging anywhere on the
//   panel resizes it.
// - full: the content scrolls; pulling down while already at the top of the
//   content shrinks the panel again.

enum PanelDetent: CaseIterable {
    case collapsed, half, full

    func height(in total: CGFloat) -> CGFloat {
        switch self {
        case .collapsed: return min(120, total * 0.25)
        case .half:      return total * 0.5
        case .full:      return total * 0.92
        }
    }
}

/// Distance between the top of the scrolled content and the top of its scroll
/// view (0 = scrolled to the top, negative = scrolled down).
private struct PanelScrollTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct BottomPanel<Content: View>: View {
    @Binding var detent: PanelDetent
    private let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: CGFloat = 0
    @State private var scrollTop: CGFloat = 0
    private let handleHeight: CGFloat = 32

    init(detent: Binding<PanelDetent>, @ViewBuilder content: @escaping () -> Content) {
        _detent = detent
        self.content = content
    }

    private var contentAtTop: Bool { scrollTop >= -1 }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let fullH = PanelDetent.full.height(in: total)
            let collapsedH = PanelDetent.collapsed.height(in: total)
            // The panel's height follows the finger, so its content is always
            // laid out for the visible size (no empty gap while dragging).
            let height = min(max(detent.height(in: total) - drag, collapsedH), fullH)

            VStack(spacing: 0) {
                handle
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: PanelScrollTopKey.self,
                                        value: proxy.frame(in: .named("panelScroll")).minY)
                                })
                        content()
                    }
                }
                .coordinateSpace(.named("panelScroll"))
                .scrollIndicators(.hidden)
                .scrollDisabled(detent != .full)
                .onPreferenceChange(PanelScrollTopKey.self) { scrollTop = $0 }
            }
            .frame(width: geo.size.width, height: height, alignment: .top)
            .background(.regularMaterial,
                        in: UnevenRoundedRectangle(topLeadingRadius: Radius.xxl,
                                                   topTrailingRadius: Radius.xxl))
            .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: -2)
            .simultaneousGesture(panelDrag(total: total))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    // MARK: Handle

    private var handle: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: handleHeight)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(Text("Panneau des résultats"))
            .accessibilityAdjustableAction { direction in
                let all = PanelDetent.allCases
                guard let i = all.firstIndex(of: detent) else { return }
                switch direction {
                case .increment: if i + 1 < all.count { detent = all[i + 1] }
                case .decrement: if i > 0 { detent = all[i - 1] }
                @unknown default: break
                }
            }
    }

    // MARK: Drag

    /// At full height the content scrolls, so the panel only follows a drag
    /// that pulls down from the very top of the content.
    private func followsDrag(_ translation: CGFloat) -> Bool {
        detent != .full || (contentAtTop && translation > 0)
    }

    private func panelDrag(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, state, _ in
                if followsDrag(value.translation.height) { state = value.translation.height }
            }
            .onEnded { value in
                guard followsDrag(value.translation.height) else { return }
                let projected = detent.height(in: total) - value.predictedEndTranslation.height
                let target = PanelDetent.allCases.min {
                    abs($0.height(in: total) - projected) < abs($1.height(in: total) - projected)
                } ?? detent
                withAnimation(reduceMotion ? nil : .snappy) { detent = target }
            }
    }
}
