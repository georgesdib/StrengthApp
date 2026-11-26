import SwiftUI
import StrengthCore

struct RootView: View {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel(watchConnectivity: LiveWatchConnectivitySession.shared)
        PhoneIntentBridge.model = model
        _model = StateObject(wrappedValue: model)
    }

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
            // A notification tap can launch the app; consume it before the ordinary start path so
            // the rest card is requested while the scene is visible.
            WatchRestReceiver.shared.applicationBecameActive()
            model.startNetworkMonitoring()
            await model.onLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            WatchRestReceiver.shared.applicationBecameActive()
            Task { await model.appBecameActive() }
        }
    }
}

struct MainTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            TodayView(model: model)
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(AppTab.today)
            HistoryView(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)
            ProgressDashboardView(model: model)
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.progress)
            ExplainView(model: model)
                .tabItem { Label("Explain", systemImage: "doc.text.magnifyingglass") }
                .tag(AppTab.explain)
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .sheet(isPresented: $model.showReadinessSheet) {
            NavigationStack {
                ReadinessFormView(model: model)
            }
        }
        .safeAreaInset(edge: .bottom) {
            RestTimerBar(timer: model.restTimer)
        }
    }
}
