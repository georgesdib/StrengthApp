import SwiftUI

struct TodayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Try again") {
                            Task { await model.refresh() }
                        }
                    }
                }

                Section("Server") {
                    LabeledContent("Date", value: model.today?.date
                                   ?? model.bootstrap?.serverDate ?? "—")
                    if let bootstrap = model.bootstrap {
                        LabeledContent("Time", value: Self.clockLabel(bootstrap.serverTime))
                        LabeledContent("Time zone", value: bootstrap.serverTimezone)
                    }
                }

                Section("Readiness") {
                    readinessContent
                }

                Section("Active workout") {
                    if let workout = model.today?.activeWorkout {
                        LabeledContent("Session", value: workout.sessionType ?? "Workout")
                        if let date = workout.forDate {
                            LabeledContent("Date", value: date)
                        }
                        LabeledContent("Status", value: workout.status ?? "in progress")
                        if let started = workout.startedAt {
                            LabeledContent("Started", value: started)
                        }
                    } else {
                        Text("No active workout")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)
                    .accessibilityLabel("Refresh today")
                }
            }
            .refreshable { await model.refresh() }
            .task {
                if model.today == nil {
                    await model.refresh()
                }
            }
            .overlay {
                if model.isRefreshing && model.today == nil {
                    ProgressView("Loading today…")
                }
            }
        }
    }

    @ViewBuilder
    private var readinessContent: some View {
        if let score = model.today?.readinessScore ?? model.today?.readiness?.score {
            LabeledContent("Status", value: Self.statusLabel(score.status))
            LabeledContent("Score", value: Self.scoreLabel(score.score))
            if let basis = score.basis, !basis.isEmpty {
                Text(basis)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let overrides = score.overrides, !overrides.isEmpty {
                DisclosureGroup("Manual overrides") {
                    ForEach(overrides.keys.sorted(), id: \.self) { scope in
                        if let override = overrides[scope] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.scopeLabel(scope))
                                    .font(.subheadline)
                                if let value = override.value {
                                    Text("Value: \(value, specifier: "%.2f")")
                                        .font(.footnote)
                                }
                                if let reason = override.reason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if let flags = score.contextFlags, !flags.isEmpty {
                LabeledContent("Context", value: flags.joined(separator: ", "))
            }
            if score.deviceSuppressed == true {
                Text("Device-derived readiness inputs were suppressed for this day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No readiness payload yet.")
                .foregroundStyle(.secondary)
        }
    }

    private static func clockLabel(_ serverTime: String) -> String {
        // ISO-8601 local wall clock, e.g. 2026-11-07T17:05:34+00:00 -> 17:05.
        let parts = serverTime.split(separator: "T")
        guard parts.count == 2 else { return serverTime }
        return String(parts[1].prefix(5))
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "ready": return "Ready"
        case "insufficient": return "Insufficient data"
        case "unknown": return "Unknown"
        default: return status.capitalized
        }
    }

    private static func scoreLabel(_ score: Double?) -> String {
        guard let score else { return "No score" }
        return "\(Int((score * 100).rounded()))%"
    }

    private static func scopeLabel(_ scope: String) -> String {
        if scope == "global" { return "Global" }
        if scope.hasPrefix("category:") {
            return "Category: " + String(scope.dropFirst("category:".count)).capitalized
        }
        return scope.capitalized
    }
}
