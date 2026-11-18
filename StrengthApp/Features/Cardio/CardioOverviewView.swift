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
                    Text("From heart-rate samples of \(tiz.eligibleWorkouts) workouts with complete "
                         + "recordings (\(Int((tiz.coverageShare * 100).rounded()))% of those with "
                         + "heart rate). Sample-based, so it is not the weekly total.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("cardio-time-in-zone")
            }

            if let weeks = payload?.summary.weeks, !weeks.isEmpty {
                Section("Last 12 weeks") {
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
                    Text(message).font(.caption).foregroundStyle(.secondary)
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
}
