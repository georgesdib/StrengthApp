import SwiftUI

@main
struct StrengthWatchApp: App {
    @StateObject private var session = WatchSessionController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView(session: session)
                .task { session.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        session.sceneBecameActive()
                    }
                }
        }
    }
}

private struct WatchRootView: View {
    @ObservedObject var session: WatchSessionController

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Strength")
                .font(.headline)
            switch session.state {
            case .waiting:
                Text("Open Strength on your iPhone to pair.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .ready(let host):
                Text("Ready")
                    .font(.footnote)
                    .foregroundStyle(.green)
                Text(host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .revoked:
                Text("Watch unpaired")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Open Strength on your iPhone to pair again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .unavailable(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if let error = session.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
