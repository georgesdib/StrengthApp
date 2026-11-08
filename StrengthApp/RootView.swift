import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to your server…")
                        .foregroundStyle(.secondary)
                }
            case .pairing:
                PairingView(model: model)
            case .paired:
                MainTabView(model: model)
            }
        }
        .task {
            model.startNetworkMonitoring()
            await model.onLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.appBecameActive() }
        }
    }
}

struct MainTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            TodayView(model: model)
                .tabItem { Label("Today", systemImage: "sun.max") }
            HistoryView(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            ProgressDashboardView(model: model)
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
