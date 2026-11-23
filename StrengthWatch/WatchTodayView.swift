import SwiftUI
import StrengthCore

/// Today on the wrist: how the athlete is, what there is to start, and — when there is nothing —
/// why not and what fixes it. Readiness, reason and the scene/connection diagnostics come from the
/// same plan read the watch already makes.
struct WatchTodayView: View {
    @ObservedObject var today: WatchTodayController
    @ObservedObject var execution: WatchExecutionController
    @ObservedObject var session: WatchSessionController

    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let spike = session.spikeStatus {
                    Text(spike)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-connection-status")
                }
                readinessLine
                content
            }
        }
        .sheet(isPresented: $showingSettings) {
            WatchSettingsView()
        }
    }

    // MARK: - Header

    private var header: some View {
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
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("watch-open-settings")
        }
    }

    // MARK: - How am I today

    /// One block, two lines at most. The number is the server's score; nothing here is computed
    /// on the watch.
    @ViewBuilder
    private var readinessLine: some View {
        if let readiness = today.readiness {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(readiness.statusWord)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let scoreText = readiness.scoreText {
                        Text(scoreText)
                            .font(.caption2.bold())
                    }
                }
                if !readiness.drivers.isEmpty {
                    Text(readiness.drivers.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("watch-readiness")
        } else {
            Text("\(dateLabel) · Not scored yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("watch-readiness")
        }
    }

    /// "2026-11-21" as "21 Nov". Anything unexpected is shown as the server sent it.
    private var dateLabel: String {
        guard let raw = today.serverDate, raw.count >= 10 else {
            return today.serverDate ?? "Today"
        }
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3 else { return String(raw.prefix(10)) }
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        guard let month = Int(parts[1]), (1...12).contains(month) else {
            return String(raw.prefix(10))
        }
        return "\(Int(parts[2]) ?? 0) \(months[month - 1])"
    }

    // MARK: - What there is to start

    @ViewBuilder
    private var content: some View {
        switch today.state {
        case .loading:
            ProgressView("Loading…")
        case .ready(let plan):
            planView(plan)
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
        case .offline(let plan, let detail):
            if let plan {
                Text("Offline · showing last plan")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                planView(plan)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-today-offline-reason")
                }
            } else if let copy = WatchTodayCopy.empty(for: today.state) {
                emptyState(copy)
            }
        case .missingCredentials, .noPlan, .phonePlan, .unsupportedTarget, .unavailable:
            if let copy = WatchTodayCopy.empty(for: today.state) {
                emptyState(copy)
            }
        }
    }

    /// Three lines: what this is, why there is nothing, and the one thing that fixes it.
    private func emptyState(_ copy: WatchTodayEmptyCopy) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(copy.title)
                .font(.headline)
            if let detail = copy.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            if let action = copy.action {
                Text(action)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("watch-today-\(copy.identifier)")
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
