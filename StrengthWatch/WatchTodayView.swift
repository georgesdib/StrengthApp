import SwiftUI
import StrengthCore

struct WatchTodayView: View {
    @ObservedObject var today: WatchTodayController
    @ObservedObject var execution: WatchExecutionController
    @ObservedObject var session: WatchSessionController
    @ObservedObject private var scenes = WatchSceneAutomation.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Today")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await today.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(today.isRefreshing)
                    .accessibilityIdentifier("watch-today-refresh")
                    Button {
                        session.testConnectivity()
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("watch-test-connection")
                }
                if let spike = session.spikeStatus {
                    Text(spike)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-connection-status")
                }

                switch today.state {
                case .loading:
                    ProgressView("Loading plan…")
                case .missingCredentials:
                    message("Open Strength on your iPhone to pair the watch.")
                case .noPlan:
                    message("No workout for Apple Watch.")
                case .phonePlan:
                    message("This workout is planned for iPhone.")
                case .unsupportedTarget:
                    message("This plan is not available on Apple Watch.")
                case .generating(let elapsed):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView()
                        Text("Building workout…")
                            .font(.footnote)
                        if let elapsed {
                            Text("\(elapsed)s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .ready(let plan):
                    planView(plan)
                case .offline(let plan, let detail):
                    if let plan {
                        Text("Offline · showing last plan")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        planView(plan)
                        if let detail { offlineReason(detail) }
                    } else {
                        message("Could not load your plan.")
                        if let detail { offlineReason(detail) }
                    }
                case .unavailable(let text):
                    message(text)
                }

                sceneStatus
            }
        }
    }

    /// What the watch knows about the phone's Home scenes. This is the only way to tell "the
    /// mapping never arrived" from "HomeKit refused on the watch" without a Mac.
    private var sceneStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
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
            if scenes.status.startLabel != nil {
                Button {
                    Task { await scenes.testStartScene() }
                } label: {
                    Text("Test start scene")
                        .font(.caption2)
                }
                .accessibilityIdentifier("watch-test-scene")
            }
        }
        .padding(.top, 4)
    }

    private func offlineReason(_ detail: String) -> some View {
        Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("watch-today-offline-reason")
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
    }

    private func planView(_ plan: WatchPlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.sessionType)
                .font(.headline)
            if !plan.forDate.isEmpty {
                Text(plan.forDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.exerciseLabel)
                        .font(.subheadline)
                    Text("\(item.setsLabel) × \(item.repsLabel) · \(item.loadLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(item.effortLabel) · \(item.restLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let warmup = item.warmupLabel, !warmup.isEmpty {
                        Text("Warm-up \(warmup)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            if !plan.warnings.isEmpty {
                Text(plan.warnings.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await execution.start(issuedPlanID: plan.issuedPlanID) }
            } label: {
                if execution.isWorking {
                    ProgressView()
                } else {
                    Text("Start on Apple Watch")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(execution.isWorking || plan.issuedPlanID.isEmpty)
            .accessibilityIdentifier("watch-start")
            if let error = execution.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
