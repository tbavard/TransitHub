import CoreGraphics

// MARK: - Spacing scale
//
// One source of truth for the layout rhythm, replacing the scattered literals
// (4/6/8/10/12/16/22/32…) used across the views. Steps roughly follow the
// existing usage clusters so the redesign stays visually close where intended.

enum Spacing {
    /// 2 — hairline gaps inside a compact label (icon ↔ text).
    static let xxs: CGFloat = 2
    /// 4 — tight intra-component spacing.
    static let xs: CGFloat = 4
    /// 6 — default gap between an icon and its label.
    static let s: CGFloat = 6
    /// 8 — small stack spacing.
    static let sm: CGFloat = 8
    /// 10 — row content spacing.
    static let m: CGFloat = 10
    /// 12 — standard gap between cards / rows.
    static let md: CGFloat = 12
    /// 14 — card inner padding.
    static let lg: CGFloat = 14
    /// 16 — screen horizontal margin.
    static let xl: CGFloat = 16
    /// 22 — gap between major sections.
    static let xxl: CGFloat = 22
    /// 32 — bottom scroll inset.
    static let xxxl: CGFloat = 32
}

// MARK: - Corner radius scale

enum Radius {
    /// 4 — provider badge chip.
    static let xs: CGFloat = 4
    /// 8 — route pill.
    static let sm: CGFloat = 8
    /// 10 — inline alert row.
    static let md: CGFloat = 10
    /// 14 — secondary card.
    static let lg: CGFloat = 14
    /// 16 — primary card / header.
    static let xl: CGFloat = 16
    /// 22 — large hero surfaces.
    static let xxl: CGFloat = 22
}
