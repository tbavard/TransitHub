import SwiftUI

@main
struct TransitHubApp: App {
    @StateObject private var providersStore: UserProvidersStore
    @StateObject private var appVM: AppViewModel
    @StateObject private var liveActivityManager = LiveActivityManager()

    init() {
        let store = UserProvidersStore()
        _providersStore = StateObject(wrappedValue: store)
        _appVM = StateObject(wrappedValue: AppViewModel(providersStore: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appVM)
                .environmentObject(providersStore)
                .environmentObject(liveActivityManager)
                .onAppear { appVM.loadData() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var providersStore: UserProvidersStore

    var body: some View {
        if providersStore.providers.isEmpty && !appVM.isLoading {
            // Fresh install — no providers configured. The main tab view shows
            // the empty-state CTA on every tab.
            MainTabView()
        } else if appVM.isLoading {
            LoadingView(progress: appVM.loadingProgress, message: appVM.loadingMessage)
        } else if let error = appVM.loadingError {
            ErrorView(error: error)
        } else {
            MainTabView()
        }
    }
}

// MARK: - LoadingView

struct LoadingView: View {
    let progress: Double
    let message: String

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 96, height: 96)
                    .shadow(color: Theme.brandStart.opacity(0.35), radius: 16, x: 0, y: 8)
                Image(systemName: "tram.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .accessibilityHidden(true)   // decorative
                    .foregroundStyle(.white)
            }

            Text("TransitHub")
                .font(Typography.screenTitle)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Theme.brandStart)
                .frame(maxWidth: 280)

            Text(message)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding()
    }
}

// MARK: - ErrorView

struct ErrorView: View {
    @EnvironmentObject var appVM: AppViewModel
    let error: Error

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 52))
                .accessibilityHidden(true)   // decorative
                .foregroundStyle(.orange)

            Text("Impossible de charger les données")
                .font(.headline)

            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Réessayer") {
                appVM.loadData()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
