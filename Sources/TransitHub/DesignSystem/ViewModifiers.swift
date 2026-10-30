import SwiftUI

// MARK: - Card
//
// Encapsulates the repeated "secondary background + rounded corners + hairline
// border + crisp shadow" pattern used by every card in the app.

struct CardModifier: ViewModifier {
    var cornerRadius: CGFloat = Radius.xl
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .background(Theme.cardBackground,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.hairline.opacity(0.25), lineWidth: 0.5)
            )
            .shadow(color: elevated ? Theme.cardShadowElevated : Theme.cardShadow,
                    radius: elevated ? 5 : 3, x: 0, y: 2)
    }
}

extension View {
    /// Standard card surface (background + radius + hairline + shadow).
    func card(cornerRadius: CGFloat = Radius.xl, elevated: Bool = false) -> some View {
        modifier(CardModifier(cornerRadius: cornerRadius, elevated: elevated))
    }
}

// MARK: - Reduce Motion
//
// Spring/scale/bounce effects are replaced by nothing (or a plain fade) when
// the user enables Settings > Accessibility > Reduce Motion.

private struct MotionSafeAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct CardScrollTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition { content, phase in
                content
                    .opacity(phase.isIdentity ? 1 : 0.4)
                    .scaleEffect(phase.isIdentity ? 1 : 0.96)
            }
        }
    }
}

extension View {
    /// `.animation(_:value:)` that is skipped under Reduce Motion.
    func motionSafe<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionSafeAnimation(animation: animation, value: value))
    }

    /// Gentle fade/scale of cards entering the viewport (no-op under Reduce Motion).
    func cardScrollTransition() -> some View {
        modifier(CardScrollTransition())
    }
}

/// `withAnimation` that is skipped when Reduce Motion is on (for state changes
/// triggered from closures, where the view environment is not available).
@MainActor
func withMotionAnimation<R>(_ animation: Animation? = .default,
                            _ body: () throws -> R) rethrows -> R {
    try withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : animation, body)
}

// MARK: - Scaled decorative icon
//
// Large hero/empty-state symbols: sized from a base point size but scaled with
// Dynamic Type (a fixed `.font(.system(size:))` ignores the user's text size).

private struct ScaledIcon: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(_ base: CGFloat, weight: Font.Weight) {
        self._size = ScaledMetric(wrappedValue: base, relativeTo: .largeTitle)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    func scaledIcon(_ base: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledIcon(base, weight: weight))
    }
}

// MARK: - Minimum touch target

extension View {
    /// Expands the tappable area to at least 44×44 pt without changing the
    /// visual size of the content.
    func minTouchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}

// MARK: - Brand gradient header
//
// A hero surface filled with the signature brand gradient, used by the
// dashboard header and prominent CTAs.

struct BrandGradientHeaderModifier: ViewModifier {
    var cornerRadius: CGFloat = Radius.xl

    func body(content: Content) -> some View {
        content
            .background(Theme.brandGradient,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Theme.brandStart.opacity(0.25), radius: 10, x: 0, y: 6)
    }
}

extension View {
    /// Fills the view's background with the brand gradient (hero header style).
    func brandGradientHeader(cornerRadius: CGFloat = Radius.xl) -> some View {
        modifier(BrandGradientHeaderModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Pill / capsule tint
//
// A tinted capsule chip (icon + label) — used for status pills and tags.

extension View {
    /// Wraps the view in a tinted capsule (fill = color at low alpha).
    func tintedCapsule(_ color: Color) -> some View {
        self
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs + 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
