import SwiftUI

struct TodayView: View {
    @ObservedObject var model: AppModel
    @State private var pendingReadinessAck = false
    @State private var lastIssueKey: String?
    @State private var lastIssueAck = false
    @State private var lastIssueConfirmations: [String: Bool]?

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

                if let error = model.mutationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if case .failed(let message) = model.prescriptionState,
                   lastIssueKey != nil {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Retry issue") { retryIssue() }
                    }
                }

                if !model.pendingMutations.isEmpty {
                    Section("Pending operation") {
                        Text("A request was sent but not confirmed. It is kept with its original operation ID and will be retried against the server.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(model.pendingMutations) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.kind.label)
                                    .font(.subheadline)
                                Text("\(entry.state == .conflict ? "Conflict" : "Awaiting confirmation") · \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let target = entry.targetId {
                                    Text(target)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if let message = model.recoveryMessage {
                            Text(message).foregroundStyle(.red)
                        }
                        Button {
                            Task { await model.retryPendingMutations() }
                        } label: {
                            HStack {
                                Spacer()
                                if model.isRecovering {
                                    ProgressView()
                                } else {
                                    Text("Retry pending operation")
                                }
                                Spacer()
                            }
                        }
                        .disabled(model.isRecovering || model.isSaving)
                        Button("Discard pending operation", role: .destructive) {
                            model.discardPendingMutations()
                        }
                        .disabled(model.isSaving)
                    }
                }

                if let issue = model.recoveryIssue {
                    Section("Recovery") {
                        switch issue {
                        case .serverActiveWorkout(let workoutId, let sessionType):
                            Text("The server has an active workout that this session did not have locally.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("\(sessionType ?? "Workout") · \(workoutId)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            NavigationLink {
                                ActiveWorkoutView(model: model)
                            } label: {
                                Label("Resume server workout", systemImage: "arrow.clockwise")
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                model.clearRecoveryIssue()
                            })
                            Button("Abandon server workout", role: .destructive) {
                                Task { await model.abandonRecoveredWorkout() }
                            }
                            .disabled(model.isSaving)
                            Button("Dismiss") { model.clearRecoveryIssue() }

                        case .workoutEndedElsewhere(let workoutId):
                            Text("Workout \(workoutId) is no longer active on the server. It may have been completed or abandoned elsewhere.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Refresh server state") {
                                Task { await model.refresh() }
                            }
                            Button("Clear local state") {
                                model.clearWorkoutRecovery()
                            }

                        case .prescriptionUnavailable(let reason):
                            Text(reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Refresh server state") {
                                Task {
                                    await model.refresh()
                                    model.clearRecoveryIssue()
                                }
                            }
                            Button("Dismiss") { model.clearRecoveryIssue() }
                        }
                    }
                }

                Section("Training") {
                    trainingContent
                }
                .disabled(!model.pendingMutations.isEmpty)

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

                if model.bootstrap?.capabilities.healthkitReadiness == true {
                    Section("HealthKit") {
                        healthKitContent
                    }
                }

                Section("Active workout") {
                    if let workout = model.activeWorkout ?? model.today?.activeWorkout {
                        LabeledContent("Session", value: workout.sessionType ?? "Workout")
                        if let date = workout.forDate {
                            LabeledContent("Date", value: date)
                        }
                        LabeledContent("Status", value: workout.status)
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
                        Task { await model.refreshWithHealthKit() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing || model.isImportingHealthKit)
                    .accessibilityLabel("Refresh today")
                }
            }
            .refreshable { await model.refreshWithHealthKit() }
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
            .sheet(isPresented: showingIssuedPlan) {
                PrescriptionPreviewView(model: model)
            }
            .alert("Readiness is not score-ready", isPresented: showingReadinessPrompt) {
                Button("Start anyway") { issuePrescription(acknowledge: true) }
                Button("Cancel", role: .cancel) { model.clearPrescription() }
            } message: {
                Text(readinessPromptText)
            }
            .confirmationDialog(
                "Confirm the server's training decision",
                isPresented: showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Accept") { issueConfirmation(accept: true) }
                Button("Proceed without") { issueConfirmation(accept: false) }
                Button("Cancel", role: .cancel) { model.clearPrescription() }
            } message: {
                Text("The server needs a deload or drop decision before issuing the plan.")
            }
        }
    }

    @ViewBuilder
    private var trainingContent: some View {
        if model.canWrite {
            if let workout = model.activeWorkout ?? model.today?.activeWorkout {
                NavigationLink {
                    ActiveWorkoutView(model: model)
                } label: {
                    Label("Resume workout (\(workout.sessionType ?? "session"))",
                          systemImage: "figure.strengthtraining.traditional")
                }
                .accessibilityIdentifier("resume-workout")
            } else {
                if model.canWriteReadiness {
                    NavigationLink {
                        ReadinessFormView(model: model)
                    } label: {
                        Label("Log readiness", systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("log-readiness")
                }
                if model.canPrescribe {
                    Button {
                        startPrescription()
                    } label: {
                        Label("Start workout", systemImage: "play.circle")
                    }
                    .accessibilityIdentifier("start-workout")
                    .disabled(model.isSaving)
                }
            }
        } else if model.bootstrap != nil {
            Text("This server has iOS writes disabled.")
                .foregroundStyle(.secondary)
        }
    }

    private var showingIssuedPlan: Binding<Bool> {
        Binding(
            get: {
                if case .issued = model.prescriptionState { return true }
                return false
            },
            set: { presented in
                if !presented { model.clearPrescription() }
            }
        )
    }

    private var showingReadinessPrompt: Binding<Bool> {
        Binding(
            get: {
                if case .readinessRequired = model.prescriptionState { return true }
                return false
            },
            set: { presented in
                if !presented { model.clearPrescription() }
            }
        )
    }

    private var showingConfirmation: Binding<Bool> {
        Binding(
            get: {
                if case .confirmationRequired = model.prescriptionState { return true }
                return false
            },
            set: { presented in
                if !presented { model.clearPrescription() }
            }
        )
    }

    private var readinessPromptText: String {
        guard case .readinessRequired(let details) = model.prescriptionState else {
            return ""
        }
        let status = details["status"]?.stringValue ?? "unknown"
        let basis = details["basis"]?.stringValue ?? ""
        return "The server reports \(status) readiness. \(basis) Start without a score?"
    }

    private func startPrescription() {
        // If the last issue response was lost, Start is not a new plan request: retry the exact
        // operation and body rather than creating a different plan.
        if case .failed = model.prescriptionState,
           model.mutationFailureAmbiguous,
           lastIssueKey != nil {
            retryIssue()
            return
        }
        pendingReadinessAck = false
        lastIssueAck = false
        lastIssueConfirmations = nil
        lastIssueKey = UUID().uuidString.lowercased()
        guard let key = lastIssueKey else { return }
        Task {
            await model.issuePrescription(
                readinessAck: false, idempotencyKey: key
            )
        }
    }

    private func issuePrescription(acknowledge: Bool) {
        pendingReadinessAck = acknowledge
        lastIssueAck = acknowledge
        lastIssueConfirmations = nil
        lastIssueKey = UUID().uuidString.lowercased()
        guard let key = lastIssueKey else { return }
        Task {
            await model.issuePrescription(
                readinessAck: acknowledge, idempotencyKey: key
            )
        }
    }

    private func issueConfirmation(accept: Bool) {
        guard case .confirmationRequired(let details) = model.prescriptionState else {
            return
        }
        let keys = details.keys.filter { $0 == "deload" || $0 == "drop" }
        let confirmations = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, accept) }
        )
        lastIssueConfirmations = confirmations
        lastIssueAck = pendingReadinessAck
        lastIssueKey = UUID().uuidString.lowercased()
        guard let key = lastIssueKey else { return }
        Task {
            await model.issuePrescription(
                readinessAck: pendingReadinessAck,
                confirmations: confirmations,
                idempotencyKey: key
            )
        }
    }

    private func retryIssue() {
        guard let key = lastIssueKey else { return }
        Task {
            await model.issuePrescription(
                readinessAck: lastIssueAck,
                confirmations: lastIssueConfirmations,
                idempotencyKey: key
            )
        }
    }

    @ViewBuilder
    private var healthKitContent: some View {
        if !model.healthKitEnabled {
            Text("HealthKit readiness is off. Enable it in Settings to import HRV and resting HR.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            if let message = model.healthKitState.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let payload = model.today?.readiness {
                healthKitValueRow(
                    "HRV", field: "hrv_ms", value: payload.hrvMs,
                    unit: "ms", payload: payload
                )
                healthKitValueRow(
                    "Resting HR", field: "rhr_bpm", value: payload.rhrBpm,
                    unit: "bpm", payload: payload
                )
            }
            Button {
                Task { await model.importHealthKit() }
            } label: {
                HStack {
                    Spacer()
                    if model.isImportingHealthKit {
                        ProgressView()
                    } else {
                        Text("Import from HealthKit")
                    }
                    Spacer()
                }
            }
            .accessibilityIdentifier("healthkit-import")
            .disabled(model.isImportingHealthKit || !model.canUseHealthKit)
        }
    }

    @ViewBuilder
    private func healthKitValueRow(
        _ label: String,
        field: String,
        value: Double?,
        unit: String,
        payload: ReadinessPayload
    ) -> some View {
        let provenance = payload.healthkit?[field]
        let source = payload.sources?[field]
        if let value {
            LabeledContent(label, value: "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
            if source == "manual", let provenance {
                Text("Manual selected; HealthKit \(provenance.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit) from \(provenance.sourceName) \(sampleAgeLabel(provenance.sampleAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let provenance {
                Text("\(provenance.sourceName) \(sampleAgeLabel(provenance.sampleAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("\(label): no sample")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sampleAgeLabel(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return "sample time unknown" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: date, relativeTo: Date())
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
