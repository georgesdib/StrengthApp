import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case pairing
        case paired
    }

    enum PrescriptionState {
        case idle
        case readinessRequired([String: JSONValue])
        case confirmationRequired([String: JSONValue])
        case issued(IssuedPlanResponse)
        case failed(String)
    }

    enum RecoveryIssue: Equatable {
        case serverActiveWorkout(workoutId: String, sessionType: String?)
        case workoutEndedElsewhere(workoutId: String)
        case prescriptionUnavailable(reason: String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var bootstrap: BootstrapResponse?
    @Published private(set) var today: TodayResponse?
    @Published private(set) var sessions: [HistorySession] = []
    @Published private(set) var historyTotal = 0
    @Published private(set) var isPairing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasLoadedHistory = false
    @Published private(set) var device: PairingDevice?
    @Published private(set) var pairedServerURL: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pairingError: String?
    @Published private(set) var activeWorkout: WorkoutDetail?
    @Published private(set) var progress: ProgressResponse?
    @Published private(set) var progressError: String?
    @Published private(set) var hasLoadedProgress = false
    @Published private(set) var prescriptionState: PrescriptionState = .idle
    @Published private(set) var isSaving = false
    @Published private(set) var isLoadingProgress = false
    @Published private(set) var mutationError: String?
    @Published private(set) var mutationFailureAmbiguous = false
    @Published private(set) var pendingMutations: [PendingMutation] = []
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var recoveryIssue: RecoveryIssue?
    @Published private(set) var isRecovering = false
    @Published private(set) var healthKitEnabled: Bool
    @Published private(set) var healthKitState: HealthKitReadinessState
    @Published private(set) var isImportingHealthKit = false
    @Published private(set) var healthKitSelection: HealthKitReadinessSelection?

    @Published var serverURLText: String
    @Published var pairingCodeText: String = ""
    @Published var pairingLabelText: String

    private static let healthKitDefaultsKey = "healthKitReadinessEnabled"
    private let client: IOSAPIClient
    private let tokens: TokenStoring
    private let store: PairedStore
    private let healthKit: any HealthKitReadinessProviding
    private let healthKitDefaults: UserDefaults
    private let pageSize = 50
    private var session: IOSSession?
    private var historyOffset = 0
    private var workoutRefreshGrace = false
    private var healthKitOperation = OperationKey<HealthKitReadinessRequest>()
    private var healthKitFollowUp = false

    init(
        client: IOSAPIClient? = nil,
        tokens: TokenStoring? = nil,
        store: PairedStore? = nil,
        healthKit: (any HealthKitReadinessProviding)? = nil,
        healthKitDefaults: UserDefaults = .standard
    ) {
        let store = store ?? PairedStore()
        let readiness = healthKit ?? HealthKitReadinessService()
        let enabled = healthKitDefaults.bool(forKey: Self.healthKitDefaultsKey)
        self.client = client ?? IOSAPIClient(journal: MutationJournal())
        self.tokens = tokens ?? KeychainTokenStore()
        self.store = store
        self.healthKit = readiness
        self.healthKitDefaults = healthKitDefaults
        self.healthKitEnabled = enabled
        self.healthKitState = enabled
            ? (readiness.isAvailable ? .enabled : .unavailable)
            : .featureDisabled
        self.serverURLText = store.serverURL ?? AppConfig.defaultServerURL
        self.pairingLabelText = store.device?.label ?? "iPhone"
    }

    var hasMoreHistory: Bool {
        sessions.count < historyTotal
    }

    var appVersion: String {
        AppConfig.versionText
    }

    var canWriteReadiness: Bool {
        bootstrap?.capabilities.readinessWrite == true
    }

    var canPrescribe: Bool {
        bootstrap?.capabilities.prescription == true
    }

    var canWriteWorkout: Bool {
        bootstrap?.capabilities.workoutWrite == true
    }

    var canWrite: Bool {
        canWriteReadiness && canPrescribe && canWriteWorkout
    }

    var canUseHealthKit: Bool {
        healthKit.isAvailable && bootstrap?.capabilities.healthkitReadiness == true
    }

    // MARK: Lifecycle

    func onLaunch() async {
        guard phase == .loading else { return }
        guard let savedURL = store.serverURL,
              let token = tokens.load(),
              let baseURL = try? IOSAPIClient.validatedBaseURL(savedURL) else {
            phase = .pairing
            return
        }
        session = IOSSession(
            baseURL: baseURL,
            token: token,
            deviceID: store.device?.deviceID
        )
        device = store.device
        pairedServerURL = baseURL.absoluteString
        serverURLText = baseURL.absoluteString
        if let device { pairingLabelText = device.label }
        phase = .paired
        await refresh()
        await recoverPendingMutations()
        if healthKitEnabled {
            await importHealthKit()
        }
    }

    // MARK: Pairing

    func pair() async {
        guard !isPairing else { return }
        pairingError = nil
        let baseURL: URL
        let code: String
        let label: String
        do {
            baseURL = try IOSAPIClient.validatedBaseURL(serverURLText)
        } catch {
            pairingError = message(for: error)
            return
        }
        do {
            code = try IOSAPIClient.normalizeCode(pairingCodeText)
        } catch {
            pairingError = message(for: error)
            return
        }
        do {
            label = try IOSAPIClient.normalizeLabel(pairingLabelText)
        } catch {
            pairingError = message(for: error)
            return
        }

        isPairing = true
        defer { isPairing = false }
        do {
            let response = try await client.pair(baseURL: baseURL, code: code, label: label)
            try tokens.save(response.token)
            let paired = PairingDevice(
                deviceID: response.device.deviceId,
                label: response.device.label
            )
            store.serverURL = baseURL.absoluteString
            store.device = paired
            device = paired
            pairedServerURL = baseURL.absoluteString
            serverURLText = baseURL.absoluteString
            pairingLabelText = response.device.label
            pairingCodeText = ""
            session = IOSSession(
                baseURL: baseURL,
                token: response.token,
                deviceID: response.device.deviceId
            )
            phase = .paired
            await refresh()
            await recoverPendingMutations()
            if healthKitEnabled {
                await importHealthKit()
            }
        } catch {
            pairingError = message(for: error)
        }
    }

    // MARK: Reads

    func refresh() async {
        guard let session, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let bootstrapTask = client.bootstrap(session: session)
            async let todayTask = client.today(session: session)
            let (newBootstrap, newToday) = try await (bootstrapTask, todayTask)
            bootstrap = newBootstrap
            today = newToday
            let previousActive = activeWorkout
            if let serverActive = newToday.activeWorkout {
                if previousActive?.workoutId != serverActive.workoutId {
                    recoveryIssue = .serverActiveWorkout(
                        workoutId: serverActive.workoutId,
                        sessionType: serverActive.sessionType
                    )
                }
                activeWorkout = serverActive
                workoutRefreshGrace = false
            } else if let previousActive, previousActive.status == "in_progress" {
                if workoutRefreshGrace {
                    // A mutation just returned an in-progress workout. Keep it for this read;
                    // the next refresh can still reconcile an externally finished workout.
                    workoutRefreshGrace = false
                    activeWorkout = previousActive
                } else {
                    // The server no longer has the workout this session was showing. Do not
                    // silently keep stale local state; surface it for reconciliation.
                    activeWorkout = nil
                    recoveryIssue = .workoutEndedElsewhere(
                        workoutId: previousActive.workoutId
                    )
                }
            } else {
                activeWorkout = nil
                workoutRefreshGrace = false
            }
            if !healthKitEnabled {
                healthKitState = .featureDisabled
            } else if !canUseHealthKit {
                healthKitState = .unavailable
            } else if healthKitState == .featureDisabled || healthKitState == .unavailable {
                healthKitState = .enabled
            }
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func loadHistory(reset: Bool = false) async {
        guard let session, !isLoadingHistory else { return }
        if reset {
            historyOffset = 0
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await client.history(
                session: session,
                limit: pageSize,
                offset: historyOffset
            )
            historyTotal = page.total
            if reset {
                sessions = page.sessions
            } else {
                sessions.append(contentsOf: page.sessions)
            }
            // The server pages by a stable order; de-duplicating keeps a refresh/load-more race
            // from showing the same session twice.
            var seen = Set<String>()
            sessions = sessions.filter { seen.insert($0.sessionId).inserted }
            historyOffset = sessions.count
            hasLoadedHistory = true
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func loadMoreHistory() async {
        guard hasMoreHistory else { return }
        await loadHistory(reset: false)
    }

    // MARK: Phase 2 mutations

    func saveReadiness(
        values: [String: Double],
        note: String?,
        idempotencyKey: String
    ) async -> Bool {
        guard !isSaving, let session else { return false }
        guard permitsMutation(kind: .readiness, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            _ = try await client.writeReadiness(
                ReadinessWriteRequest(values: values, note: note),
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            await refresh()
            return true
        } catch {
            handleMutation(error)
            return false
        }
    }

    // MARK: HealthKit readiness (Phase 3A)

    func setHealthKitEnabled(_ enabled: Bool) async {
        guard enabled != healthKitEnabled else { return }
        if !enabled {
            healthKitDefaults.set(false, forKey: Self.healthKitDefaultsKey)
            healthKitEnabled = false
            healthKitSelection = nil
            healthKitState = .featureDisabled
            healthKitOperation = OperationKey<HealthKitReadinessRequest>()
            healthKitFollowUp = false
            return
        }
        guard canUseHealthKit else {
            healthKitState = .unavailable
            return
        }
        healthKitDefaults.set(true, forKey: Self.healthKitDefaultsKey)
        healthKitEnabled = true
        healthKitState = .enabled
        healthKitOperation = OperationKey<HealthKitReadinessRequest>()
        do {
            try await healthKit.requestAuthorization()
        } catch {
            healthKitState = .importError(message(for: error))
            return
        }
        await importHealthKit()
    }

    func refreshWithHealthKit() async {
        await refresh()
        if healthKitEnabled {
            await importHealthKit()
        }
    }

    func importHealthKit() async {
        guard healthKitEnabled else {
            healthKitState = .featureDisabled
            return
        }
        guard canUseHealthKit else {
            healthKitState = .unavailable
            return
        }
        guard let session, let date = today?.date else {
            healthKitState = .importError("Refresh Today before importing HealthKit readiness.")
            return
        }
        if isImportingHealthKit {
            healthKitFollowUp = true
            return
        }
        await runHealthKitImport(session: session, date: date)
        while healthKitFollowUp {
            healthKitFollowUp = false
            guard healthKitEnabled, canUseHealthKit,
                  let currentSession = self.session,
                  let currentDate = today?.date else { break }
            await runHealthKitImport(session: currentSession, date: currentDate)
        }
    }

    private func runHealthKitImport(session: IOSSession, date: String) async {
        isImportingHealthKit = true
        defer {
            isImportingHealthKit = false
            refreshPendingMutations()
        }
        do {
            let selection = try await healthKit.selectSamples(
                serverDate: date,
                now: Date()
            )
            healthKitSelection = selection
            if selection.isEmpty {
                healthKitState = selection.hasStaleSample ? .staleSample : .noEligibleSample
                return
            }
            healthKitState = .eligibleSample
            let request = HealthKitReadinessRequest(
                date: date,
                samples: selection.observations.map(\.payload)
            )
            let key = healthKitOperation.use(request)
            guard permitsMutation(kind: .healthkitReadiness, operationId: key) else {
                healthKitState = .importError(
                    mutationError ?? "Another operation is awaiting confirmation."
                )
                return
            }
            _ = try await client.importHealthKitReadiness(
                request,
                session: session,
                idempotencyKey: key
            )
            healthKitOperation.acknowledged()
            mutationError = nil
            await refresh()
        } catch {
            healthKitState = .importError(message(for: error))
            handleMutation(error)
        }
    }

    func issuePrescription(
        readinessAck: Bool,
        confirmations: [String: Bool]? = nil,
        idempotencyKey: String
    ) async {
        guard !isSaving, let session else { return }
        guard permitsMutation(kind: .prescription, operationId: idempotencyKey) else {
            return
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        mutationError = nil
        do {
            let issued = try await client.issuePrescription(
                IssuePrescriptionRequest(
                    readinessAck: readinessAck,
                    confirmations: confirmations
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
            prescriptionState = .issued(issued)
            await refresh()
        } catch let error as APIError {
            if error.isAuthenticationFailure {
                handle(error)
                return
            }
            switch error.code {
            case "readiness_required":
                prescriptionState = .readinessRequired(error.details ?? [:])
            case "confirmation_required":
                prescriptionState = .confirmationRequired(error.details ?? [:])
            default:
                handleMutation(error)
                prescriptionState = .failed(message(for: error))
            }
        } catch {
            handleMutation(error)
            prescriptionState = .failed(message(for: error))
        }
    }

    func clearPrescription() {
        prescriptionState = .idle
        mutationError = nil
        mutationFailureAmbiguous = false
    }

    func startWorkout(idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, case .issued(let issued) = prescriptionState else {
            return false
        }
        guard permitsMutation(kind: .startWorkout, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            activeWorkout = try await client.startWorkout(
                issuedPlanId: issued.issuedPlanId,
                session: session,
                idempotencyKey: idempotencyKey
            )
            // Keep the issued state so the preview sheet stays presented and can switch to
            // the active workout. The sheet binding clears it when the sheet is dismissed.
            mutationError = nil
            recoveryIssue = nil
            workoutRefreshGrace = true
            await refresh()
            return true
        } catch {
            if let api = error as? APIError, api.isAuthenticationFailure {
                handle(error)
                return false
            }
            if let api = error as? APIError {
                let code = api.code ?? ""
                if ["plan_consumed", "plan_expired", "plan_superseded"].contains(code) {
                    prescriptionState = .idle
                    recoveryIssue = .prescriptionUnavailable(
                        reason: "This prescription is no longer available. Refresh to load the current server state."
                    )
                    await refresh()
                } else if code == "workout_active" {
                    prescriptionState = .idle
                    await refresh()
                }
            }
            handleMutation(error)
            return false
        }
    }

    func addSet(_ body: AddSetRequest, idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        guard permitsMutation(kind: .addSet, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            activeWorkout = try await client.addSet(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            workoutRefreshGrace = true
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func rateForm(_ body: FormRatingRequest, idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        guard permitsMutation(kind: .rateForm, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            activeWorkout = try await client.rateForm(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            workoutRefreshGrace = true
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func completeWorkout(
        _ body: CompleteWorkoutRequest,
        idempotencyKey: String
    ) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        guard permitsMutation(kind: .completeWorkout, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            activeWorkout = try await client.completeWorkout(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            recoveryIssue = nil
            workoutRefreshGrace = false
            await refresh()
            await loadHistory(reset: true)
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func abandonWorkout(idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        guard permitsMutation(kind: .abandonWorkout, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            activeWorkout = try await client.abandonWorkout(
                workoutId: workout.workoutId,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            recoveryIssue = nil
            workoutRefreshGrace = false
            await refresh()
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func loadProgress(weeks: Int = 8) async {
        guard let session, !isLoadingProgress else { return }
        isLoadingProgress = true
        defer { isLoadingProgress = false }
        do {
            progress = try await client.progress(weeks: weeks, session: session)
            progressError = nil
            hasLoadedProgress = true
        } catch {
            if let api = error as? APIError, api.isAuthenticationFailure {
                handle(error)
            } else {
                progressError = message(for: error)
            }
        }
    }

    // MARK: Durable pending operations

    func recoverPendingMutations() async {
        guard let session, !isRecovering, !isSaving else { return }
        let entries = client.pendingMutations(for: session)
        pendingMutations = entries
        guard !entries.isEmpty else {
            recoveryMessage = nil
            return
        }
        isRecovering = true
        defer {
            isRecovering = false
            refreshPendingMutations()
        }
        var message: String?
        for entry in entries {
            guard entry.state == .pending else {
                message = "\(entry.kind.label) has an unresolved conflict."
                continue
            }
            guard entry.isReplayable else {
                client.markConflict(entry)
                message = "\(entry.kind.label) is older than the safe replay window. Discard it and verify the server state."
                continue
            }
            do {
                switch entry.kind {
                case .readiness, .healthkitReadiness:
                    let _: ReadinessPayload = try await client.replay(entry, session: session)
                case .prescription:
                    let issued: IssuedPlanResponse = try await client.replay(entry, session: session)
                    prescriptionState = .issued(issued)
                case .startWorkout, .addSet, .rateForm:
                    activeWorkout = try await client.replay(entry, session: session)
                    workoutRefreshGrace = true
                case .completeWorkout, .abandonWorkout:
                    activeWorkout = try await client.replay(entry, session: session)
                    workoutRefreshGrace = false
                }
            } catch let api as APIError {
                if api.code == "idempotency_conflict" {
                    message = "A pending \(entry.kind.label.lowercased()) conflicts with a previous request. Discard it and refresh."
                    break
                }
                if !Self.isAmbiguous(api) {
                    message = api.errorDescription
                    continue
                }
                message = api.errorDescription
                break
            } catch {
                message = self.message(for: error)
                break
            }
        }
        recoveryMessage = message
        await refresh()
    }

    func retryPendingMutations() async {
        await recoverPendingMutations()
    }

    func discardPendingMutations() {
        guard let session else { return }
        client.discardAll(for: session)
        pendingMutations = []
        recoveryMessage = nil
        mutationError = nil
        mutationFailureAmbiguous = false
    }

    func clearRecoveryIssue() {
        recoveryIssue = nil
    }

    func clearWorkoutRecovery() {
        // Clear stale local state; the server remains the authority on the next refresh.
        activeWorkout = nil
        recoveryIssue = nil
        workoutRefreshGrace = false
        mutationError = nil
    }

    func abandonRecoveredWorkout() async {
        guard !isSaving, activeWorkout != nil else { return }
        let key = UUID().uuidString.lowercased()
        if await abandonWorkout(idempotencyKey: key) {
            recoveryIssue = nil
        }
    }

    private func refreshPendingMutations() {
        guard let session else {
            pendingMutations = []
            return
        }
        pendingMutations = client.pendingMutations(for: session)
    }

    /// A new mutation may proceed only when there is no unresolved operation, or when this is
    /// the exact operation being retried. This keeps the journal bounded and ordered.
    private func permitsMutation(kind: MutationKind, operationId: String) -> Bool {
        let unresolved = pendingMutations
        guard !unresolved.isEmpty else { return true }
        if unresolved.contains(where: {
            $0.kind == kind && $0.operationId == operationId && $0.state == .pending
        }) {
            return true
        }
        mutationError = "A previous operation is still awaiting confirmation. Retry or discard it before starting another."
        return false
    }

    // MARK: Local credential management

    func forgetDevice() {
        forgetLocally(message: nil)
    }

    private func forgetLocally(message: String?) {
        if let session {
            client.discardAll(for: session)
        }
        tokens.delete()
        store.device = nil
        device = nil
        session = nil
        bootstrap = nil
        today = nil
        sessions = []
        historyTotal = 0
        historyOffset = 0
        hasLoadedHistory = false
        activeWorkout = nil
        progress = nil
        progressError = nil
        hasLoadedProgress = false
        prescriptionState = .idle
        isSaving = false
        isLoadingProgress = false
        mutationError = nil
        mutationFailureAmbiguous = false
        pendingMutations = []
        recoveryMessage = nil
        recoveryIssue = nil
        isRecovering = false
        workoutRefreshGrace = false
        healthKitDefaults.set(false, forKey: Self.healthKitDefaultsKey)
        healthKitEnabled = false
        healthKitState = .featureDisabled
        healthKitSelection = nil
        healthKitOperation = OperationKey<HealthKitReadinessRequest>()
        healthKitFollowUp = false
        pairedServerURL = store.serverURL
        phase = .pairing
        errorMessage = nil
        pairingError = message
    }

    private func handleMutation(_ error: Error) {
        if let api = error as? APIError, api.isAuthenticationFailure {
            mutationFailureAmbiguous = false
            forgetLocally(message: api.errorDescription)
        } else {
            mutationError = message(for: error)
            mutationFailureAmbiguous = Self.isAmbiguous(error)
        }
    }

    /// A transport failure, a decoding failure, or a 5xx may have reached the server even though
    /// the client has no definitive response. A 4xx without a response body is definitive.
    private static func isAmbiguous(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return true }
        switch api {
        case .transport, .decoding:
            return true
        case .http(let status, _, _), .server(let status, _, _, _, _):
            return status >= 500
        case .invalidBaseURL, .invalidPairingCode, .invalidLabel,
             .journal, .unauthorized, .forbidden:
            return false
        }
    }

    private func handle(_ error: Error) {
        if let api = error as? APIError, api.isAuthenticationFailure {
            forgetLocally(message: api.errorDescription)
        } else {
            errorMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
