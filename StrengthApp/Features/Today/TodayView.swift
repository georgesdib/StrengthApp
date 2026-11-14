import SwiftUI
import StrengthCore

struct TodayView: View {
    @ObservedObject var model: AppModel
    @State private var pendingReadinessAck = false
    @State private var lastIssueKey: String?
    @State private var lastIssueAck = false
    @State private var lastIssueConfirmations: [String: Bool]?
    @State private var lastIssueSettings = PlanSettings()
    @State private var lastIssueTarget: PrescriptionExecutionTarget = .phone
    @State private var draftSettings = PlanSettings()
    @State private var draftTarget: PrescriptionExecutionTarget = .phone
    @State private var showingPlanSettings = false
    @State private var showingWorkout = false
    @State private var showingReview = false
    @State private var startAfterReview = false
    @State private var confirmingDiscardOffline = false

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
                                Label("Open on this iPhone", systemImage: "iphone")
                            }
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

                if let message = model.offlineRecoveryMessage {
                    Section("Offline recovery") {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Text("The local recovery file could not be read. Offline capture is paused; retry or explicitly discard the unreadable file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry recovery load") {
                            _ = model.retryOfflineRecovery()
                        }
                        Button("Discard unreadable recovery data", role: .destructive) {
                            confirmingDiscardOffline = true
                        }
                    }
                }

                if let conflict = model.offlineRecoveryConflict {
                    Section("Offline recovery conflict") {
                        Text("The active workout is \(conflict.currentWorkoutID), but the recovered capture belongs to \(conflict.recoveredWorkoutID) with \(conflict.pendingOperationCount) pending operation(s).")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Text("Choose which work to keep. The other side is discarded explicitly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Keep current workout and discard recovered work", role: .destructive) {
                            Task { _ = await model.keepCurrentWorkoutAndDiscardRecoveredWork() }
                        }
                        Button("Use recovered workout") {
                            _ = model.useRecoveredWorkoutAfterConflict()
                        }
                    }
                }

                if let error = model.offlinePersistenceError {
                    Section("Offline capture write failed") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let error = model.offlineTelemetryError {
                    Section("Execution timing") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if model.hasPendingOfflineCapture {
                    Section("Offline capture") {
                        Label(
                            model.isOffline ? "Offline — saved on this phone" : "Pending server acknowledgement",
                            systemImage: model.isOffline ? "wifi.slash" : "clock.arrow.circlepath"
                        )
                        .foregroundStyle(.orange)
                        if let error = model.offlineSyncError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        if model.isSyncingOffline {
                            HStack {
                                ProgressView()
                                Text("Syncing…")
                            }
                        } else {
                            Button("Sync now") {
                                Task { await model.syncOfflineCapture() }
                            }
                            .disabled(model.isSaving)
                        }
                        ForEach(model.pendingOfflineOperations) { operation in
                            HStack {
                                Text(operation.kind.label)
                                Spacer()
                                if operation.state == .expired {
                                    Text("Expired")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                    Button("Discard", role: .destructive) {
                                        Task { _ = await model.discardOfflineOperation(operation.operationId) }
                                    }
                                    .font(.caption)
                                } else if operation.state == .failed || operation.state == .conflict {
                                    Text(operation.state.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                    Button("Retry") {
                                        Task { _ = await model.retryOfflineOperation(operation.operationId) }
                                    }
                                    .font(.caption)
                                    Button("Discard", role: .destructive) {
                                        Task { _ = await model.discardOfflineOperation(operation.operationId) }
                                    }
                                    .font(.caption)
                                } else if operation.isCancellable {
                                    Button("Cancel", role: .destructive) {
                                        Task { _ = await model.cancelOfflineOperation(operation.operationId) }
                                    }
                                    .font(.caption)
                                } else {
                                    Text("Pending")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Discard all local capture", role: .destructive) {
                            confirmingDiscardOffline = true
                        }
                        .font(.footnote)
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
            .navigationDestination(isPresented: $showingWorkout) {
                ActiveWorkoutView(model: model)
            }
            .sheet(isPresented: $showingPlanSettings) {
                PlanSettingsView(
                    settings: $draftSettings,
                    executionTarget: $draftTarget
                ) {
                    showingPlanSettings = false
                    beginPrescription(with: draftSettings, target: draftTarget)
                }
            }
            .sheet(isPresented: $showingReview, onDismiss: {
                if startAfterReview {
                    startAfterReview = false
                    showingWorkout = true
                }
            }) {
                PrescriptionPreviewView(model: model) {
                    startAfterReview = true
                    showingReview = false
                }
            }
            .alert("Discard all offline capture?", isPresented: $confirmingDiscardOffline) {
                Button("Discard", role: .destructive) {
                    Task { _ = await model.discardAllOfflineCapture() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The cached workout and every queued local operation will be removed. Nothing unsent will reach the server.")
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
            if model.offlineFinishPending {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Finished locally — waiting to sync", systemImage: "clock.badge.checkmark")
                        .foregroundStyle(.orange)
                    Text("The session is saved on this phone but is not server-confirmed yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.isSyncingOffline {
                        HStack { ProgressView(); Text("Syncing…") }
                    } else {
                        Button("Sync now") {
                            Task { await model.syncOfflineCapture() }
                        }
                        .font(.footnote)
                    }
                    Button("Cancel queued finish", role: .destructive) {
                        Task { _ = await model.cancelOfflineFinish() }
                    }
                    .font(.footnote)
                }
                .accessibilityIdentifier("offline-finish-pending")
            } else if let workout = model.activeWorkout ?? model.today?.activeWorkout {
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
                    if case .generating(let progress) = model.prescriptionState {
                        generatingCard(progress)
                    } else if case .issued(let issued) = model.prescriptionState {
                        readyCard(issued)
                    } else {
                        Button {
                            startPrescription()
                        } label: {
                            Label("Request workout", systemImage: "play.circle")
                        }
                        .accessibilityIdentifier("start-workout")
                        .disabled(model.isSaving || model.isOffline || model.hasPendingOfflineCapture)
                        if model.isOffline || model.hasPendingOfflineCapture {
                            Text("Requesting a workout requires the server.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else if model.bootstrap != nil {
            Text("This server has iOS writes disabled.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func readyCard(_ issued: IssuedPlanResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Workout ready", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .accessibilityIdentifier("workout-ready")
            Text("\(Self.label(issued.sessionType)) · \(issued.forDate)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(issued.plan.items.count) exercise\(issued.plan.items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !issued.warnings.isEmpty {
                Text(issued.warnings.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if issued.executionTarget == "watch" {
                Text("Requested for Apple Watch. Review it here; start it on the watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch-targeted-plan")
            }
            // Borderless keeps the two buttons independent; the default list style made
            // either tap fire both of them.
            Button {
                showingReview = true
            } label: {
                Label("Review workout", systemImage: "list.bullet.clipboard")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("review-workout")
            Button {
                startPrescription()
            } label: {
                Label("Request another workout", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("replace-workout")
            .disabled(model.isSaving || model.isOffline || model.hasPendingOfflineCapture)
            if model.isOffline || model.hasPendingOfflineCapture {
                Text("Replacing the workout requires the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    nonisolated private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func progressLabel(_ progress: PlanProgress) -> String {
        let stage = progress.status == "queued" ? "Queued" : "Building"
        return stage + " · " + String(progress.elapsedSeconds) + "s"
    }

    @ViewBuilder
    private func generatingCard(_ progress: PlanProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView()
                Text("Generating your workout…")
            }
            Text(Self.progressLabel(progress))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if progress.elapsedSeconds >= 60 {
                Text("Still generating. You can leave this screen; the server keeps building and the plan will be here when you return.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Stop waiting") { model.clearPrescription() }
                .font(.footnote)
        }
        .accessibilityIdentifier("plan-generating")
    }

    private func startPrescription() {
        // If the last request's response was lost, Start is not a new plan request: retry the
        // exact operation and body rather than creating a different plan.
        if case .failed = model.prescriptionState,
           model.mutationFailureAmbiguous,
           lastIssueKey != nil {
            retryIssue()
            return
        }
        draftSettings = model.planSettings
        draftTarget = .phone
        showingPlanSettings = true
    }

    private func beginPrescription(
        with settings: PlanSettings,
        target: PrescriptionExecutionTarget
    ) {
        pendingReadinessAck = false
        lastIssueAck = false
        lastIssueConfirmations = nil
        lastIssueSettings = settings
        lastIssueTarget = target
        lastIssueKey = UUID().uuidString.lowercased()
        guard let key = lastIssueKey else { return }
        Task {
            await model.issuePrescription(
                readinessAck: false,
                settings: settings,
                executionTarget: target,
                idempotencyKey: key
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
                readinessAck: acknowledge,
                settings: lastIssueSettings,
                executionTarget: lastIssueTarget,
                idempotencyKey: key
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
                settings: lastIssueSettings,
                executionTarget: lastIssueTarget,
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
                settings: lastIssueSettings,
                executionTarget: lastIssueTarget,
                idempotencyKey: key
            )
        }
    }

    @ViewBuilder
    private var healthKitContent: some View {
        if !model.healthKitEnabled {
            Text("HealthKit readiness is off. Enable it in Settings to import HRV, resting HR and bodyweight.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            if let message = model.healthKitState.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let refreshError = model.healthKitRefreshError {
                Text("Readiness was saved, but the authoritative refresh failed: \(refreshError) Retry refresh; do not import again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
                healthKitValueRow(
                    "Bodyweight", field: "bodyweight_kg", value: payload.bodyweightKg,
                    unit: "kg", payload: payload
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
            let status = model.healthKitSelection.flatMap {
                HealthKitReadinessField(rawValue: field).map($0.status(for:))
            }
            switch status {
            case .stale:
                Text("\(label): stale HealthKit sample")
                    .font(.caption)
                    .foregroundStyle(.orange)
            default:
                Text("\(label): no sample")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

// MARK: - Plan settings (R7)

/// The workout settings the phone may choose. Loads, exercises and every training number stay
/// with the server; this only picks which session and whether a minimum session is acceptable.
struct PlanSettingsView: View {
    @Binding var settings: PlanSettings
    @Binding var executionTarget: PrescriptionExecutionTarget
    var onRequest: () -> Void
    @Environment(\.dismiss) private var dismiss

    private struct SessionOption: Identifiable {
        let id: String
        let label: String
    }

    private let sessionTypes: [SessionOption] = [
        SessionOption(id: "auto", label: "Auto (server decides)"),
        SessionOption(id: "squat", label: "Squat"),
        SessionOption(id: "hinge", label: "Hinge"),
        SessionOption(id: "bench_squat", label: "Bench + squat"),
        SessionOption(id: "bench_hinge", label: "Bench + hinge"),
        SessionOption(id: "accessory", label: "Accessory"),
    ]

    private enum MainLiftStructure: String, CaseIterable, Identifiable {
        case server = "Server decides"
        case topSet = "Top set + back-off"
        case straight = "Straight sets"

        var id: String { rawValue }
    }

    private var structure: Binding<MainLiftStructure> {
        Binding(
            get: {
                switch settings.topSet {
                case .some(true): return .topSet
                case .some(false): return .straight
                case nil: return .server
                }
            },
            set: { value in
                switch value {
                case .server: settings.topSet = nil
                case .topSet: settings.topSet = true
                case .straight: settings.topSet = false
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    Picker("Run on", selection: $executionTarget) {
                        ForEach(PrescriptionExecutionTarget.allCases, id: \.self) { target in
                            Text(target.label).tag(target)
                        }
                    }
                    .accessibilityIdentifier("prescription-execution-target")
                    Text("Watch-targeted plans appear on the Apple Watch Today screen and cannot be started on the iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Session") {
                    Picker("Session type", selection: $settings.sessionType) {
                        ForEach(sessionTypes) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                }
                Section("Main-lift structure") {
                    Picker("Structure", selection: structure) {
                        ForEach(MainLiftStructure.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .accessibilityIdentifier("main-lift-structure")
                    Text("Top set/back-off is applied by the server only when the resolver supports it for this session. Straight sets asks for no top-set structure.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Length") {
                    Toggle("Allow a minimum session", isOn: $settings.minimumSession)
                    if settings.minimumSession {
                        Stepper(
                            "Target: \(settings.minimumTargetMinutes ?? 30) min",
                            value: Binding(
                                get: { settings.minimumTargetMinutes ?? 30 },
                                set: { settings.minimumTargetMinutes = $0 }
                            ),
                            in: 10...120,
                            step: 5
                        )
                    }
                }
                Section {
                    Text("The server builds the prescription. This only chooses the session type, main-lift structure and whether a shortened session is acceptable. With the resolver enabled, the server uses it to build the plan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Request workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Request") { onRequest() }
                        .accessibilityIdentifier("request-workout")
                }
            }
        }
    }
}
