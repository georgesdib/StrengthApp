import StrengthCore
import SwiftUI

/// Watch-side settings, opened deliberately from Today. The Home scene mapping and the reason a
/// scene did not run live here: they are setup and diagnostics, not training.
struct WatchSettingsView: View {
    @ObservedObject private var scenes = WatchSceneAutomation.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Settings")
                        .font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("watch-settings-done")
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "house")
                            .font(.caption2)
                        Text("Home scenes")
                            .font(.caption2)
                        Spacer()
                        if scenes.status.isRunning {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text(scenes.status.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("watch-scene-status")
                    if let result = scenes.status.lastResult {
                        Text(result)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier("watch-scene-result")
                    }
                    Button("Test start scene") {
                        Task { await scenes.testStartScene() }
                    }
                    .font(.caption2)
                    .disabled(scenes.status.startLabel == nil || scenes.status.isRunning)
                    .accessibilityIdentifier("watch-test-scene")
                    Text("Chosen on your iPhone under Settings → Workout automation.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                // The Watch app's install handoff gives up silently, so the build on the wrist
                // has to be readable there: compare it with the commit that was installed.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer")
                            .font(.caption2)
                        Text("Build")
                            .font(.caption2)
                        Spacer()
                    }
                    Text(BuildStamp.current)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-build-stamp")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await scenes.preload()
            scenes.refresh()
        }
    }
}
