import SwiftUI

// MARK: - NoProvidersView
//
// Empty-state CTA shown by every main tab when the user hasn't added any
// transit providers yet. Drills directly into `SettingsView`, which is also
// where the "+ Add" button lives.

struct NoProvidersView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tram.circle")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            Text("Aucun fournisseur configuré")
                .font(.title3.weight(.semibold))
            Text("Ajoutez un réseau de transport pour voir ses lignes, ses arrêts et ses horaires.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            NavigationLink {
                SettingsView()
            } label: {
                Label("Ouvrir les réglages", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
