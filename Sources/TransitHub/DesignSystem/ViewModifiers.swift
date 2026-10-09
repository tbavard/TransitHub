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
