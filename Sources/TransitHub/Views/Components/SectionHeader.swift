import SwiftUI

// MARK: - Section header
//
// Small colored-icon + title header used above dashboard sections.

struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .font(Typography.caption.weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(Typography.sectionTitle)
        }
    }
}
