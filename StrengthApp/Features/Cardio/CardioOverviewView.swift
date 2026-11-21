import SwiftUI
import StrengthCore

/// Compact cardio overview (C6b). Reads the authenticated summary; the only action is a sync, which
/// calls the same path Settings uses rather than a second implementation.
struct CardioOverviewView: View {
    @ObservedObject var model: AppModel
    @State private var payload: CardioActivityPayload?
    @State private var error: String?
    @State private var loading = false

    private var week28: CardioRolling? { payload?.summary.rolling["28d"] }
    private var week7: CardioRolling? { payload?.summary.rolling["7d"] }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            payload = try await model.loadCardioActivity(tiz: true)
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? "The cardio summary could not be loaded."
        }
    }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Try again") { Task { await load() } }
                }
            }

            Section {
                Text("This page is the imported record: what Apple Health sent, how it was "
                     + "classified, and what could not be classified. The weekly figure is an "
                     + "estimate from Apple's METs or a workout's average heart rate; time in zone "
                     + "comes from the heart-rate samples themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    metric("Last 7 days", week7?.equivalentMinutes)
                    Divider()
                    metric("Last 28 days", week28?.equivalentMinutes)
                }
                .padding(.vertical, 4)
                Text("WHO-equivalent minutes: moderate + 2 × vigorous, classified from Apple's METs "
                     + "or heart rate. Unclassified time is reported, never counted as zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let tiz = payload?.assessment?.timeInZone {
                Section("Time in zone") {
                    HStack {
                        metric("\(tiz.windowDays)-day moderate", tiz.moderateMinutes)
                        Divider()
                        metric("\(tiz.windowDays)-day vigorous", tiz.vigorousMinutes)
                    }
                    .padding(.vertical, 4)
                    Text(timeInZoneDetail(tiz))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("cardio-time-in-zone")
            }

            if let weeks = payload?.summary.weeks, !weeks.isEmpty {
                Section("Last 12 weeks") {
                    Text("Weekly totals from the imported workouts. A week with no workout is "
                         + "shown as zero because it genuinely had none, not because data is missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(weeks.suffix(12)) { week in
                        HStack {
                            Text(week.isoWeek).font(.caption.monospaced())
                            Spacer()
                            Text("\(Int(week.equivalentMinutes.rounded())) min")
                            if week.resistanceMinutes > 0 {
                                Text("· \(Int(week.resistanceMinutes.rounded())) lifting")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let recent = payload?.recent, !recent.isEmpty {
                Section("Recent workouts") {
                    Text("The five most recent imported workouts. \"hidden\" removes a workout from "
                         + "the totals without deleting it; nothing here edits Apple Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(recent) { workout in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(workout.activity).font(.subheadline)
                                Text(workout.startedAt.prefix(10)).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(workout.minutes) min").font(.caption)
                            if workout.hidden {
                                Text("hidden").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    Task {
                        await model.syncHealthKitActivity()
                        await load()
                    }
                } label: {
                    if model.isSyncingActivity || loading {
                        HStack { ProgressView(); Text("Syncing…") }
                    } else {
                        Text("Sync now")
                    }
                }
                .disabled(model.isSyncingActivity || !model.canSyncActivity)
                if let message = model.activitySyncMessage {
                    HStack(alignment: .top, spacing: 6) {
                        if model.activitySyncNeedsAttention {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(model.activitySyncNeedsAttention ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("cardio-sync-status")
                }
                if model.activitySyncNeedsAttention {
                    Button("Dismiss warning") {
                        model.dismissActivityQuarantine()
                    }
                    .font(.caption)
                    .accessibilityIdentifier("cardio-sync-dismiss")
                }
                if let latest = payload?.summary.latestWorkoutAt {
                    Text("Last recorded workout: \(latest.prefix(10))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Cardio")
        .task { await load() }
        .refreshable { await load() }
    }

    private func metric(_ title: String, _ minutes: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(minutes.map { "\(Int($0.rounded())) min" } ?? "—")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Coverage is stated separately from continuity eligibility: the gate says a recording is
    /// usable, not that it spans the whole workout. Unobserved minutes are never extrapolated.
    private func timeInZoneDetail(_ tiz: CardioTimeInZone) -> String {
        var text = "From heart-rate samples of \(tiz.eligibleWorkouts) workouts with continuous "
            + "recordings (\(Int((tiz.coverageShare * 100).rounded()))% of those with heart rate)."
        if let covered = tiz.coveredMinutes, let total = tiz.workoutMinutes {
            let pct = Int(((tiz.temporalCoverageShare ?? 0) * 100).rounded())
            text += "\n\(Self.minutes(covered)) of \(Self.minutes(total)) workout minutes had "
                + "usable samples (\(pct)% temporal coverage); unobserved minutes are not "
                + "assigned to a zone."
        }
        text += "\nSample-based, so it is not the weekly total."
        return text
    }

    private static func minutes(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
