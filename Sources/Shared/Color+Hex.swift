import SwiftUI

// MARK: - Color from hex string
//
// Single canonical definition, compiled into BOTH the app and the widget
// target (both include `Sources/Shared`). Previously this lived in
// GTFSModels.swift (app-only, leaving the widget's `Color(hex:)` calls
// undefined) with a `hexShared` work-around in SharedDataStore.swift.

extension Color {
    /// Creates a color from a 6-digit `RRGGBB` hex string (with or without a
    /// leading `#`). Returns `nil` when the string isn't a valid 6-digit hex.
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >>  8) & 0xFF) / 255.0,
            blue:  Double( rgb        & 0xFF) / 255.0
        )
    }
}
