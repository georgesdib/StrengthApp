import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()

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
        .task { await model.onLaunch() }
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
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
