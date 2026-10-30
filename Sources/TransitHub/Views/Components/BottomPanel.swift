import SwiftUI

// MARK: - Bottom panel
//
// A draggable panel docked to the bottom of its container with three resting
// heights, like the Google Maps / Apple Maps sheets. Unlike `.sheet` it lives
// inside the screen, so the tab bar stays reachable and the map behind keeps
// responding to touches outside the panel.

enum PanelDetent: CaseIterable {
    case collapsed, half, full

    func height(in total: CGFloat) -> CGFloat {
        switch self {
        case .collapsed: return min(150, total * 0.3)
        case .half:      return total * 0.5
        case .full:      return total * 0.92
        }
    }
}

struct BottomPanel<Content: View>: View {
    @Binding var detent: PanelDetent
    private let content: () -> Content

    @GestureState private var drag: CGFloat = 0
    private let handleHeight: CGFloat = 32

    init(detent: Binding<PanelDetent>, @ViewBuilder content: @escaping () -> Content) {
        _detent = detent
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let fullH = PanelDetent.full.height(in: total)
            let collapsedH = PanelDetent.collapsed.height(in: total)
            let currentH = detent.height(in: total)
            // The panel is laid out once at full height and slid up/down, so
            // dragging never re-lays out its content.
            let offset = min(max(fullH - currentH + drag, 0), fullH - collapsedH)

            VStack(spacing: 0) {
                handle(total: total)
                content()
                    .frame(height: max(currentH - handleHeight, 0), alignment: .top)
                    .clipped()
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: fullH, alignment: .top)
            .background(.regularMaterial,
                        in: UnevenRoundedRectangle(topLeadingRadius: Radius.xxl,
                                                   topTrailingRadius: Radius.xxl))
            .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: -2)
            .offset(y: offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func handle(total: CGFloat) -> some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: handleHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in state = value.translation.height }
                    .onEnded { value in
                        let projected = detent.height(in: total) - value.predictedEndTranslation.height
                        let target = PanelDetent.allCases.min {
                            abs($0.height(in: total) - projected) < abs($1.height(in: total) - projected)
                        } ?? detent
                        withMotionAnimation(.snappy) { detent = target }
                    }
            )
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
}
