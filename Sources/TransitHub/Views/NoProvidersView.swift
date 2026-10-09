import SwiftUI

// MARK: - NoProvidersView
//
// Empty-state CTA shown by every main tab when the user hasn't added any
// transit providers yet. Drills directly into `SettingsView`, which is also
// where the "+ Add" button lives.

struct NoProvidersView: View {
    var body: some View {
        VStack(spacing: Spacing.xxl) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 104, height: 104)
                    .shadow(color: Theme.brandStart.opacity(0.35), radius: 16, x: 0, y: 8)
                Image(systemName: "tram.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: Spacing.sm) {
                Text("Aucun fournisseur configuré")
                    .font(.title3.weight(.semibold))
                Text("Ajoutez un réseau de transport pour voir ses lignes, ses arrêts et ses horaires.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xxl)
            }

            NavigationLink {
                SettingsView()
            } label: {
                Label("Ajouter un réseau", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.md)
                    .brandGradientHeader(cornerRadius: Radius.lg)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
