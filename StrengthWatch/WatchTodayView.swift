import SwiftUI
import StrengthCore

struct WatchTodayView: View {
    @ObservedObject var today: WatchTodayController

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
                case .offline(let plan):
                    if let plan {
                        Text("Offline · showing last plan")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        planView(plan)
                    } else {
                        message("Connect to home Wi-Fi to load your plan.")
                    }
                case .unavailable(let text):
                    message(text)
                }
            }
        }
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
                }
                .padding(.vertical, 2)
            }
            if !plan.warnings.isEmpty {
                Text(plan.warnings.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Read-only preview")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
