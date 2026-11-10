import SwiftUI

@main
struct StrengthWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

private struct WatchRootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Strength")
                .font(.headline)
            Text("Open Strength on your iPhone to get started.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
