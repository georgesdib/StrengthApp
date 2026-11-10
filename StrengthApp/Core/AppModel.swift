import Combine
import Foundation
import StrengthCore

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
        case generating(PlanProgress)
        case issued(IssuedPlanResponse)
        case failed(String)
    }

    enum RecoveryIssue: Equatable {
        case serverActiveWorkout(workoutId: String, sessionType: String?)
        case workoutEndedElsewhere(workoutId: String)
        case prescriptionUnavailable(reason: String)
    }

    struct RefreshOutcome: Equatable {
        let succeeded: Bool
        let message: String?

        static let success = RefreshOutcome(succeeded: true, message: nil)

        static func failure(_ message: String) -> RefreshOutcome {
            RefreshOutcome(succeeded: false, message: message)
        }
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var bootstrap: BootstrapResponse?
    @Published private(set) var today: TodayResponse?
    @Published private(set) var sessions: [HistorySession] = []
    @Published private(set) var historyTotal = 0
    @Published private(set) var isPairing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var healthKitRefreshError: String?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasLoadedHistory = false
    @Published private(set) var device: PairingDevice?
    @Published private(set) var pairedServerURL: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pairingError: String?
    @Published private(set) var activeWorkout: WorkoutDetail?
    @Published private(set) var offlineCapture: OfflineCapture?
    @Published private(set) var isOffline = false
    @Published private(set) var isSyncingOffline = false
    @Published private(set) var offlineSyncError: String?
    @Published private(set) var exerciseCatalogue: [ExerciseOption] = []
    @Published private(set) var isLoadingExerciseCatalogue = false
    @Published private(set) var exerciseCatalogueError: String?
    @Published private(set) var exerciseDetail: ExerciseDetailResponse?
    @Published private(set) var isLoadingExerciseDetail = false
    @Published private(set) var exerciseDetailError: String?
    @Published private(set) var exerciseHistorySessions: [ExerciseHistorySession] = []
    @Published private(set) var exerciseHistoryIncluded: [ExerciseHistoryIncluded] = []
    @Published private(set) var exerciseHistoryTotal = 0
    @Published private(set) var exerciseHistoryHasMore = false
    @Published private(set) var isLoadingExerciseHistory = false
    @Published private(set) var exerciseHistoryError: String?
    @Published private(set) var progress: ProgressResponse?
    @Published private(set) var progressError: String?
    @Published private(set) var hasLoadedProgress = false
    @Published private(set) var prescriptionState: PrescriptionState = .idle
    /// Settings the owner chose for the current request, kept for retry after a lost response.
    @Published private(set) var planSettings = PlanSettings()
    private var planPollTask: Task<Void, Never>?
    private var planPollFailures = 0
    private static let maxPlanPollFailures = 10
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
    @Published var homeServerText: String
    @Published var awayServerText: String
    @Published var preferHome: Bool
    @Published private(set) var activeServerRoute: ServerRoute?
    @Published private(set) var homeServerReachable: Bool?
    @Published private(set) var isCheckingHomeServer = false
    @Published private(set) var serverSettingsError: String?
    @Published var pairingCodeText: String = ""
    @Published var pairingLabelText: String

    private static let healthKitDefaultsKey = "healthKitReadinessEnabled"
    private let client: IOSAPIClient
    private let tokens: TokenStoring
    private let store: PairedStore
    private let healthKit: any HealthKitReadinessProviding
    private let healthKitDefaults: UserDefaults
    private let offlineStore: OfflineCaptureStore
    private let pageSize = 50
    private var session: IOSSession?
    private var historyOffset = 0
    private var workoutRefreshGrace = false
    private var healthKitOperation = OperationKey<HealthKitReadinessRequest>()
    private var healthKitFollowUp = false
    private var networkMonitor: NetworkMonitor?
    private var offlineRetryTask: Task<Void, Never>?
    private var offlineRetryAttempt = 0
    private var exerciseDetailCache: [String: ExerciseDetailResponse] = [:]
    private var exerciseHistoryExerciseId: String?
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshWaiters: [CheckedContinuation<RefreshOutcome, Never>] = []
    private var readinessLockBusy = false
    private var readinessLockWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        client: IOSAPIClient? = nil,
        tokens: TokenStoring? = nil,
        store: PairedStore? = nil,
        healthKit: (any HealthKitReadinessProviding)? = nil,
        healthKitDefaults: UserDefaults = .standard,
        offlineStore: OfflineCaptureStore? = nil
    ) {
        let store = store ?? PairedStore()
        store.migrateServerConfigurationIfNeeded()
        let readiness = healthKit ?? HealthKitReadinessService()
        let enabled = healthKitDefaults.bool(forKey: Self.healthKitDefaultsKey)
        let captureStore = offlineStore ?? OfflineCaptureStore()
        let initialCapture = try? captureStore.load()
        self.client = client ?? IOSAPIClient(journal: MutationJournal())
        self.tokens = tokens ?? KeychainTokenStore()
        self.store = store
        self.healthKit = readiness
        self.healthKitDefaults = healthKitDefaults
        self.offlineStore = captureStore
        self.healthKitEnabled = enabled
        self.healthKitState = enabled
            ? (readiness.isAvailable ? .enabled : .unavailable)
            : .featureDisabled
        self.serverURLText = store.serverURL ?? AppConfig.defaultServerURL
        self.homeServerText = store.homeServerURL ?? ""
        self.awayServerText = store.awayServerURL ?? ""
        self.preferHome = store.preferHome
        self.pairingLabelText = store.device?.label ?? "iPhone"
        self.offlineCapture = initialCapture
        self.activeWorkout = initialCapture?.activeWorkout
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

    var pendingOfflineOperations: [OfflineOperation] {
        offlineCapture?.operations ?? []
    }

    var pendingOfflineCount: Int { pendingOfflineOperations.count }

    var hasPendingOfflineCapture: Bool { !pendingOfflineOperations.isEmpty }

    var offlineFinishPending: Bool {
        pendingOfflineOperations.contains {
            $0.kind == .completeWorkout && $0.state == .pending
        }
    }

    var offlineCaptureActive: Bool { isOffline || hasPendingOfflineCapture }

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

    func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }
        networkMonitor = NetworkMonitor { [weak self] in
            Task { @MainActor in
                await self?.appBecameActive()
            }
        }
    }

    func onLaunch() async {
        guard phase == .loading else { return }
        homeServerText = store.homeServerURL ?? ""
        awayServerText = store.awayServerURL ?? ""
        preferHome = store.preferHome
        let configuration = store.serverConfiguration
        let token = tokens.load()
        let pairedDevice = store.device
        let selection = await chooseServerSelection(configuration, token: token)
        let savedURL = selection?.url ?? store.serverURL
        guard let savedURL,
              let baseURL = try? IOSAPIClient.validatedBaseURL(savedURL) else {
            phase = .pairing
            return
        }
        serverURLText = baseURL.absoluteString
        activeServerRoute = selection?.route ?? .home
        guard let token, let pairedDevice else {
            phase = .pairing
            return
        }
        session = IOSSession(
            baseURL: baseURL,
            token: token,
            deviceID: pairedDevice.deviceID
        )
        device = pairedDevice
        store.serverURL = baseURL.absoluteString
        pairedServerURL = baseURL.absoluteString
        pairingLabelText = pairedDevice.label
        phase = .paired
        let refreshed = await refresh()
        isOffline = !refreshed.succeeded
        await recoverPendingMutations()
        await syncOfflineCapture()
        if refreshed.succeeded, healthKitEnabled {
            await importHealthKit()
        }
    }

    private func chooseServerSelection(
        _ configuration: ServerConfiguration,
        token: String?
    ) async -> (route: ServerRoute, url: String)? {
        var homeReachable: Bool?
        let home = configuration.homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = configuration.awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.preferHome, !home.isEmpty, !away.isEmpty, home != away,
           let token, let homeURL = try? IOSAPIClient.validatedBaseURL(home) {
            isCheckingHomeServer = true
            homeReachable = await client.isServerReachable(
                baseURL: homeURL, token: token
            )
            isCheckingHomeServer = false
        }
        homeServerReachable = homeReachable
        return ServerConfiguration.select(
            homeURL: configuration.homeURL,
            awayURL: configuration.awayURL,
            preferHome: configuration.preferHome,
            homeReachable: homeReachable
        )
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
            let prior = store.serverConfiguration
            if prior.homeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.homeServerURL = baseURL.absoluteString
            } else if prior.awayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.awayServerURL = baseURL.absoluteString
            } else if activeServerRoute == .away {
                store.awayServerURL = baseURL.absoluteString
            } else {
                store.homeServerURL = baseURL.absoluteString
            }
            homeServerText = store.homeServerURL ?? ""
            awayServerText = store.awayServerURL ?? ""
            preferHome = store.preferHome
            activeServerRoute = ServerConfiguration.select(
                homeURL: store.homeServerURL ?? "",
                awayURL: store.awayServerURL ?? "",
                preferHome: store.preferHome,
                homeReachable: nil
            )?.route ?? .home
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
            let refreshed = await refresh()
            await recoverPendingMutations()
            if refreshed.succeeded, healthKitEnabled {
                await importHealthKit()
            }
        } catch {
            pairingError = message(for: error)
        }
    }

    var serverSelectionSummary: String {
        switch activeServerRoute {
        case .home:
            return "Using Home Server"
        case .away:
            return "Using Away Server"
        case nil:
            return "No server selected"
        }
    }

    var homeServerStatus: String {
        if !preferHome {
            return "Prefer Home Server is off; Away Server is used when configured."
        }
        if isCheckingHomeServer {
            return "Checking whether Home Server is reachable…"
        }
        switch homeServerReachable {
        case true:
            return "Home Server is reachable."
        case false:
            return "Home Server is unreachable; Away Server is the fallback."
        case nil:
            return "Home Server is preferred; reachability is checked on launch, foreground and network changes."
        }
    }

    func saveServerSettings() async -> Bool {
        serverSettingsError = nil
        var home = homeServerText.trimmingCharacters(in: .whitespacesAndNewlines)
        var away = awayServerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty || !away.isEmpty else {
            serverSettingsError = "Enter at least a Home Server or an Away Server."
            return false
        }
        if !home.isEmpty {
            do { home = try IOSAPIClient.validatedBaseURL(home).absoluteString } catch {
                serverSettingsError = message(for: error)
                return false
            }
        }
        if !away.isEmpty {
            do { away = try IOSAPIClient.validatedBaseURL(away).absoluteString } catch {
                serverSettingsError = message(for: error)
                return false
            }
        }
        let configuration = ServerConfiguration(
            homeURL: home, awayURL: away, preferHome: preferHome
        )
        let selected: (route: ServerRoute, url: String)?
        if phase == .paired, let token = tokens.load() {
            selected = await chooseServerSelection(configuration, token: token)
        } else {
            homeServerReachable = nil
            isCheckingHomeServer = false
            selected = ServerConfiguration.select(
                homeURL: home, awayURL: away, preferHome: preferHome,
                homeReachable: nil
            )
        }
        guard let selected else {
            serverSettingsError = "Configure at least one valid server address."
            return false
        }
        if phase == .paired, let currentSession = session,
           currentSession.baseURL.absoluteString != selected.url,
           hasPendingOfflineCapture || !pendingMutations.isEmpty {
            serverSettingsError = "Sync or discard pending offline work before switching server addresses."
            return false
        }
        store.homeServerURL = home
        store.awayServerURL = away
        store.preferHome = preferHome
        homeServerText = home
        awayServerText = away
        if phase == .pairing {
            serverURLText = selected.url
            activeServerRoute = selected.route
            return true
        }
        await recheckServerSelection(forceRefresh: true)
        return serverSettingsError == nil
    }

    func recheckServerSelection(forceRefresh: Bool = false) async {
        guard phase == .paired else { return }
        let configuration = store.serverConfiguration
        guard let token = tokens.load() else { return }
        guard let selected = await chooseServerSelection(configuration, token: token),
              let baseURL = try? IOSAPIClient.validatedBaseURL(selected.url) else {
            serverSettingsError = "Configure at least one valid server address."
            return
        }
        guard let currentSession = session,
              let pairedDevice = store.device else { return }
        let changed = currentSession.baseURL.absoluteString != baseURL.absoluteString
        if changed, hasPendingOfflineCapture || !pendingMutations.isEmpty {
            serverSettingsError = "Sync or discard pending offline work before switching server addresses."
            return
        }
        serverSettingsError = nil
        activeServerRoute = selected.route
        if changed {
            session = IOSSession(
                baseURL: baseURL,
                token: token,
                deviceID: pairedDevice.deviceID
            )
            store.serverURL = baseURL.absoluteString
            serverURLText = baseURL.absoluteString
            pairedServerURL = baseURL.absoluteString
        }
        if changed || forceRefresh {
            let outcome = await refresh()
            isOffline = !outcome.succeeded
        }
    }

    func appBecameActive() async {
        await recheckServerSelection()
        await syncOfflineCapture()
    }

    // MARK: Reads

    /// Coalescing authoritative refresh. A request arriving while another refresh is in
    /// flight is never dropped: it forces one more GET after the current one and every caller
    /// receives the final outcome.
    @discardableResult
    func refresh() async -> RefreshOutcome {
        guard session != nil else {
            return .failure("Pair this device before refreshing.")
        }
        refreshPending = true
        if !refreshInFlight {
            refreshInFlight = true
            isRefreshing = true
            Task { await self.runRefreshLoop() }
        }
        return await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
        }
    }

    private func runRefreshLoop() async {
        var last = RefreshOutcome.failure("Refresh did not complete.")
        while refreshPending {
            refreshPending = false
            last = await performRefresh()
        }
        refreshInFlight = false
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.resume(returning: last)
        }
    }

    private func performRefresh() async -> RefreshOutcome {
        await acquireReadinessLock()
        defer { releaseReadinessLock() }
        guard let session else {
            return .failure("Pair this device before refreshing.")
        }
        do {
            async let bootstrapTask = client.bootstrap(session: session)
            async let todayTask = client.today(session: session)
            let (newBootstrap, newToday) = try await (bootstrapTask, todayTask)
            bootstrap = newBootstrap
            today = newToday
            // R7: the plan area is rendered from the authoritative read, never from a cached
            // Today payload (contract section 6). An active workout wins over a plan preview.
            let planStateResponse = try? await client.planState(session: session)
            if let planStateResponse {
                if newToday.activeWorkout == nil {
                    applyPlanState(planStateResponse)
                    resumePlanPollingIfNeeded()
                } else {
                    // A workout is running, so the preview sheet is showing the workout view.
                    // Starting consumes the plan, which makes plans/current report none; clearing
                    // the state here would dismiss the sheet mid-session. The workout owns the
                    // screen until it ends.
                    stopPlanPolling()
                }
            }
            let previousActive = activeWorkout
            if hasPendingOfflineCapture {
                // Pending offline work owns the local active-workout view. A completed finish
                // leaves this nil while failed/conflict operations remain; do not resurrect a
                // server workout for that state.
                activeWorkout = offlineCapture?.activeWorkout
                workoutRefreshGrace = false
            } else if let serverActive = newToday.activeWorkout {
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
            persistActiveWorkout()
            isOffline = false
            if !healthKitEnabled {
                healthKitState = .featureDisabled
            } else if !canUseHealthKit {
                healthKitState = .unavailable
            } else if healthKitState == .featureDisabled || healthKitState == .unavailable {
                healthKitState = .enabled
            }
            healthKitRefreshError = nil
            errorMessage = nil
            return .success
        } catch {
            isOffline = true
            if activeWorkout == nil, let cached = offlineCapture?.activeWorkout {
                activeWorkout = cached
            }
            handle(error)
            return .failure(message(for: error))
        }
    }

    private func persistActiveWorkout() {
        guard activeWorkout != nil || offlineCapture == nil else { return }
        if let updated = try? offlineStore.setActiveWorkout(activeWorkout) {
            offlineCapture = updated
        }
    }

    private func acquireReadinessLock() async {
        if !readinessLockBusy {
            readinessLockBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            readinessLockWaiters.append(continuation)
        }
    }

    private func releaseReadinessLock() {
        if readinessLockWaiters.isEmpty {
            readinessLockBusy = false
        } else {
            let next = readinessLockWaiters.removeFirst()
            next.resume()
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

    func historyDetail(sessionID: String) async throws -> HistoryDetail {
        guard let session else { throw APIError.transport("Pair this device first.") }
        do {
            return try await client.historyDetail(sessionID: sessionID, session: session)
        } catch {
            handle(error)
            throw error
        }
    }

    func executionAnalytics(workoutId: String) async throws -> ExecutionAnalyticsResponse {
        guard let session else { throw APIError.transport("Pair this device first.") }
        do {
            return try await client.executionAnalytics(
                workoutId: workoutId, session: session
            )
        } catch {
            handle(error)
            throw error
        }
    }

    /// Persist execution telemetry before the UI acknowledges the action. The existing Phase 4
    /// outbox owns delivery, ordering and retry; this method never waits for the network.
    func recordExecutionEvents(_ events: [ExecutionEvent]) {
        guard !events.isEmpty, let activeWorkout else { return }
        do {
            offlineCapture = try offlineStore.appendExecutionEvents(
                workoutId: activeWorkout.workoutId,
                events: events,
                activeWorkout: activeWorkout
            )
            offlineSyncError = nil
            Task { await syncOfflineCapture() }
        } catch {
            offlineSyncError = message(for: error)
        }
    }

    func recordExecutionEvent(_ event: ExecutionEvent) {
        recordExecutionEvents([event])
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
        let outcome = await refresh()
        guard outcome.succeeded, healthKitEnabled else { return }
        await importHealthKit()
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
        healthKitRefreshError = nil
        var lockHeld = false
        defer {
            if lockHeld { releaseReadinessLock() }
            isImportingHealthKit = false
            refreshPendingMutations()
        }
        await acquireReadinessLock()
        lockHeld = true
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
            // The mutation is acknowledged and journaled before the refresh. A failed GET is
            // recoverable and must not turn a successful POST into a retry.
            lockHeld = false
            releaseReadinessLock()
            let outcome = await refresh()
            if outcome.succeeded {
                healthKitRefreshError = nil
            } else {
                healthKitRefreshError = outcome.message
                    ?? "Readiness was saved, but the authoritative refresh failed."
            }
        } catch {
            healthKitState = .importError(message(for: error))
            handleMutation(error)
        }
    }

    func issuePrescription(
        readinessAck: Bool,
        confirmations: [String: Bool]? = nil,
        settings: PlanSettings? = nil,
        idempotencyKey: String
    ) async {
        guard !isSaving, let session else { return }
        guard !hasPendingOfflineCapture else {
            mutationError = "Resolve or discard the pending offline capture before requesting another workout."
            return
        }
        guard permitsMutation(kind: .prescription, operationId: idempotencyKey) else {
            return
        }
        let settings = settings ?? PlanSettings()
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        mutationError = nil
        do {
            let ack = try await client.issuePrescription(
                IssuePrescriptionRequest(
                    readinessAck: readinessAck,
                    confirmations: confirmations,
                    settings: settings
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
            planSettings = ack.settings ?? settings
            prescriptionState = .generating(
                PlanProgress(
                    issuedPlanId: ack.issuedPlanId,
                    status: ack.status,
                    elapsedSeconds: 0,
                    settings: planSettings
                )
            )
            startPlanPolling()
            // Wait for the request to settle. The UI is not blocked — the model publishes the
            // generating card while this awaits — and "Stop waiting"/expiry cancels the poll.
            await planPollTask?.value
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
        stopPlanPolling()
        prescriptionState = .idle
        mutationError = nil
        mutationFailureAmbiguous = false
    }

    // MARK: Plan request (R7)

    /// Poll cadence for a request in flight. 60 s is a copy threshold, not a timeout, so a slow
    /// build keeps polling until the server reports a terminal state (contract section 5).
    static func planPollIntervalMs(elapsedSeconds: Int) -> Int {
        if elapsedSeconds < 10 { return 1_000 }
        if elapsedSeconds < 60 { return 2_000 }
        if elapsedSeconds < 300 { return 5_000 }
        return 10_000
    }

    private func startPlanPolling() {
        planPollTask?.cancel()
        planPollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollPlanUntilSettled()
        }
    }

    private func stopPlanPolling() {
        planPollTask?.cancel()
        planPollTask = nil
    }

    private var planElapsedSeconds: Int {
        if case .generating(let progress) = prescriptionState {
            return progress.elapsedSeconds
        }
        return 0
    }

    private func pollPlanUntilSettled() async {
        while !Task.isCancelled {
            let interval = Self.planPollIntervalMs(elapsedSeconds: planElapsedSeconds)
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            if Task.isCancelled { return }
            if await pollPlanOnce() { return }
        }
    }

    /// One authoritative read. Returns true when the request reached a terminal state.
    private func pollPlanOnce() async -> Bool {
        guard let session else { return true }
        do {
            let state = try await client.planState(session: session)
            planPollFailures = 0
            applyPlanState(state)
            switch state.status {
            case "queued", "building":
                return false
            default:
                return true
            }
        } catch let error as APIError where error.isAuthenticationFailure {
            handle(error)
            return true
        } catch {
            // A failed read is not a failed request: the plan may already exist, so keep
            // waiting. Ten consecutive failures is not a blip though, and spinning forever
            // would hide a real problem behind a card that never resolves.
            planPollFailures += 1
            if planPollFailures >= Self.maxPlanPollFailures {
                stopPlanPolling()
                prescriptionState = .failed(
                    "Could not read the plan state. The request may still finish; refresh to check."
                )
                return true
            }
            return false
        }
    }

    /// Apply the authoritative plan state. The server, not a local copy, decides what is shown.
    func applyPlanState(_ state: PlansStateResponse) {
        switch state.status {
        case "ready":
            if let issued = state.issuedPlan {
                stopPlanPolling()
                prescriptionState = .issued(issued)
            } else {
                stopPlanPolling()
                prescriptionState = .failed("The server reported a ready plan without a plan body.")
            }
        case "queued", "building":
            prescriptionState = .generating(
                PlanProgress(
                    issuedPlanId: state.issuedPlanId ?? planElapsedSettingsID,
                    status: state.status,
                    elapsedSeconds: state.elapsedSeconds ?? 0,
                    settings: state.settings ?? planSettings
                )
            )
        case "error":
            stopPlanPolling()
            prescriptionState = .failed(
                state.error?.message ?? "The plan could not be generated."
            )
        default:
            // "none": no live request. Drop a stale preview instead of offering Start on it.
            stopPlanPolling()
            if case .issued = prescriptionState {
                prescriptionState = .idle
            }
            if case .generating = prescriptionState {
                prescriptionState = .idle
            }
        }
    }

    private var planElapsedSettingsID: String {
        if case .generating(let progress) = prescriptionState {
            return progress.issuedPlanId
        }
        return ""
    }

    /// Reconcile against the server after launch or foreground. Never overrides a live request
    /// with local state (contract section 6).
    func reconcilePlanState() async {
        guard let session else { return }
        guard let state = try? await client.planState(session: session) else { return }
        applyPlanState(state)
        resumePlanPollingIfNeeded()
    }

    private func resumePlanPollingIfNeeded() {
        if case .generating = prescriptionState {
            startPlanPolling()
        }
    }

    func startWorkout(idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, case .issued(let issued) = prescriptionState else {
            return false
        }
        guard !hasPendingOfflineCapture else {
            mutationError = "Resolve or discard the pending offline capture before starting another workout."
            return false
        }
        guard permitsMutation(kind: .startWorkout, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let workout = try await client.startWorkout(
                issuedPlanId: issued.issuedPlanId,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(workout))
            try? offlineStore.clear()
            offlineCapture = try? offlineStore.load()
            persistActiveWorkout()
            recoveryIssue = nil
            workoutRefreshGrace = true
            await refresh()
            // The plan is consumed by the start. Clear the ready state after reconciliation so a
            // stale fake/current plan read cannot put the start affordance back on Today.
            prescriptionState = .idle
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
        if offlineCaptureActive {
            return queueAddSet(body, idempotencyKey: idempotencyKey, workout: workout)
        }
        guard permitsMutation(kind: .addSet, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.addSet(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(updated))
            workoutRefreshGrace = true
            persistActiveWorkout()
            return true
        } catch {
            if shouldQueueOffline(error) {
                client.discardPendingOperation(idempotencyKey)
                return queueAddSet(body, idempotencyKey: idempotencyKey, workout: workout)
            }
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func removeSet(
        workoutId: String,
        setId: Int,
        idempotencyKey: String
    ) async -> Bool {
        guard !isSaving, let session else { return false }
        guard !offlineCaptureActive else {
            mutationError = "Removing a server-confirmed set requires a connection. Pending local sets can still be removed."
            return false
        }
        guard permitsMutation(kind: .removeSet, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            activeWorkout = try await client.removeSet(
                workoutId: workoutId,
                body: RemoveSetRequest(setId: setId),
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            workoutRefreshGrace = true
            persistActiveWorkout()
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
        if offlineCaptureActive {
            return queueForm(body, idempotencyKey: idempotencyKey, workout: workout)
        }
        guard permitsMutation(kind: .rateForm, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.rateForm(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(updated))
            workoutRefreshGrace = true
            persistActiveWorkout()
            return true
        } catch {
            if shouldQueueOffline(error) {
                client.discardPendingOperation(idempotencyKey)
                return queueForm(body, idempotencyKey: idempotencyKey, workout: workout)
            }
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func loadExerciseCatalogue(force: Bool = false) async {
        guard let session else { return }
        if !force && !exerciseCatalogue.isEmpty { return }
        guard !isLoadingExerciseCatalogue else { return }
        if force {
            // Configuration is cached in memory for the session; an explicit catalogue
            // refresh invalidates it so detail screens do not keep showing old taxonomy.
            exerciseDetailCache.removeAll()
        }
        isLoadingExerciseCatalogue = true
        exerciseCatalogueError = nil
        defer { isLoadingExerciseCatalogue = false }
        do {
            exerciseCatalogue = try await client.exerciseCatalogue(session: session).exercises
        } catch {
            exerciseCatalogueError = message(for: error)
            if let api = error as? APIError, api.isAuthenticationFailure {
                forgetLocally(message: api.errorDescription)
            }
        }
    }

    func loadExerciseDetail(exerciseId: String) async {
        guard let session else { return }
        exerciseDetail = exerciseDetailCache[exerciseId]
        guard !isLoadingExerciseDetail else { return }
        isLoadingExerciseDetail = true
        exerciseDetailError = nil
        defer { isLoadingExerciseDetail = false }
        do {
            let detail = try await client.exerciseDetail(
                exerciseId: exerciseId, session: session
            )
            exerciseDetailCache[exerciseId] = detail
            exerciseDetail = detail
        } catch {
            exerciseDetailError = message(for: error)
            if let api = error as? APIError, api.isAuthenticationFailure {
                forgetLocally(message: api.errorDescription)
            }
        }
    }

    func loadExerciseHistory(exerciseId: String, reset: Bool = false) async {
        guard let session else { return }
        if reset || exerciseHistoryExerciseId != exerciseId {
            exerciseHistoryExerciseId = exerciseId
            exerciseHistorySessions = []
            exerciseHistoryIncluded = []
            exerciseHistoryTotal = 0
            exerciseHistoryHasMore = false
            exerciseHistoryError = nil
        }
        guard !isLoadingExerciseHistory else { return }
        isLoadingExerciseHistory = true
        if reset {
            exerciseHistoryError = nil
        }
        defer { isLoadingExerciseHistory = false }
        do {
            let offset = reset ? 0 : exerciseHistorySessions.count
            let response = try await client.exerciseHistory(
                exerciseId: exerciseId,
                limit: 20,
                offset: offset,
                session: session
            )
            if reset {
                exerciseHistorySessions = response.sessions
            } else {
                let existing = Set(exerciseHistorySessions.map(\.sessionId))
                exerciseHistorySessions += response.sessions.filter {
                    !existing.contains($0.sessionId)
                }
            }
            exerciseHistoryIncluded = response.includedExercises
            exerciseHistoryTotal = response.total
            exerciseHistoryHasMore = response.hasMore
        } catch {
            exerciseHistoryError = message(for: error)
            if let api = error as? APIError, api.isAuthenticationFailure {
                forgetLocally(message: api.errorDescription)
            }
        }
    }

    func swapPlanExercise(
        workoutId: String,
        itemIndex: Int,
        exerciseId: String,
        expectedExerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.swapPlanExercise(
                workoutId: workoutId,
                itemIndex: itemIndex,
                body: PlanSwapRequest(
                    exerciseId: exerciseId,
                    expectedExerciseId: expectedExerciseId
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    func removePlanExercise(
        workoutId: String,
        itemIndex: Int,
        expectedExerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.removePlanExercise(
                workoutId: workoutId,
                itemIndex: itemIndex,
                body: PlanRemoveRequest(expectedExerciseId: expectedExerciseId),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    func changePlanSets(
        workoutId: String,
        itemIndex: Int,
        delta: Int,
        expectedExerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.changePlanSets(
                workoutId: workoutId,
                itemIndex: itemIndex,
                body: PlanSetsRequest(
                    delta: delta,
                    expectedExerciseId: expectedExerciseId
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    func addPlanExercise(
        workoutId: String,
        exerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.addPlanExercise(
                workoutId: workoutId,
                body: PlanAddRequest(exerciseId: exerciseId),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    private func performPlanEdit(
        idempotencyKey: String,
        _ operation: () async throws -> WorkoutDetail
    ) async -> Bool {
        guard !isSaving, session != nil, activeWorkout != nil else { return false }
        guard !offlineCaptureActive else {
            mutationError = "Plan editing requires the server."
            return false
        }
        guard permitsMutation(kind: .planEdit, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        do {
            activeWorkout = try await operation()
            mutationError = nil
            workoutRefreshGrace = true
            persistActiveWorkout()
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed", "plan_changed",
                "sets_already_logged", "sets_below_logged", "last_plan_item",
                "exercise_already_present"].contains(api.code ?? "") {
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
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        // Execution events queued before finish must reach the server first; the API accepts
        // late events but the local replay path needs an active workout to flush them.
        if hasPendingOfflineCapture {
            await syncOfflineCapture()
        }
        if offlineCaptureActive {
            return queueFinish(body, idempotencyKey: idempotencyKey, workout: workout)
        }
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
            try? offlineStore.clear()
            offlineCapture = try? offlineStore.load()
            await refresh()
            await loadHistory(reset: true)
            return true
        } catch {
            if shouldQueueOffline(error) {
                client.discardPendingOperation(idempotencyKey)
                return queueFinish(body, idempotencyKey: idempotencyKey, workout: workout)
            }
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
        if hasPendingOfflineCapture {
            await syncOfflineCapture()
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
            try? offlineStore.clear()
            offlineCapture = try? offlineStore.load()
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
                    // The journal only proves the request was accepted. A Phase 2 receipt may
                    // still return the old synchronous body, so decode the shared field only
                    // and let the authoritative read decide what to show.
                    let ack: PlanAckEnvelope = try await client.replay(entry, session: session)
                    _ = ack
                    await reconcilePlanState()
                case .startWorkout, .addSet, .removeSet, .rateForm, .planEdit:
                    activeWorkout = try await client.replay(entry, session: session)
                    workoutRefreshGrace = true
                case .completeWorkout, .abandonWorkout:
                    activeWorkout = try await client.replay(entry, session: session)
                    workoutRefreshGrace = false
                case .executionEvents:
                    break
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

    @discardableResult
    private func apply(_ event: SessionEvent) -> [SessionEffect] {
        let current = SessionState(
            activeWorkout: activeWorkout,
            isSaving: isSaving,
            mutationError: mutationError,
            mutationFailureAmbiguous: mutationFailureAmbiguous
        )
        let (next, effects) = SessionReducer.reduce(current, event)
        activeWorkout = next.activeWorkout
        isSaving = next.isSaving
        mutationError = next.mutationError
        mutationFailureAmbiguous = next.mutationFailureAmbiguous
        for effect in effects {
            execute(effect)
        }
        return effects
    }

    private func execute(_ effect: SessionEffect) {
        switch effect {
        case .persistActiveWorkout:
            persistActiveWorkout()
        case .refreshPendingMutations:
            refreshPendingMutations()
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
    private func shouldQueueOffline(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return true }
        switch api {
        case .transport, .decoding:
            return true
        case .server(let status, _, _, _, _):
            return status >= 500
        case .http(let status, _, _):
            return status >= 500
        default:
            return false
        }
    }

    private func nowISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func queueAddSet(
        _ body: AddSetRequest,
        idempotencyKey: String,
        workout: WorkoutDetail
    ) -> Bool {
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        let performedAt = body.performedAt ?? nowISO()
        let request = AddSetRequest(
            exerciseId: body.exerciseId,
            loadKg: body.loadKg,
            reps: body.reps,
            rir: body.rir,
            velocityMps: body.velocityMps,
            setIndex: body.setIndex,
            planItemIndex: body.planItemIndex,
            repVelocities: body.repVelocities,
            performedAt: performedAt
        )
        do {
            let localId = try offlineStore.nextLocalSetId()
            let localSet = WorkoutSet(
                setId: localId,
                exerciseId: request.exerciseId,
                setIndex: request.setIndex,
                planItemIndex: request.planItemIndex,
                loadKg: request.loadKg,
                reps: request.reps,
                rir: request.rir,
                velocity: request.velocityMps,
                source: "manual",
                repsDetail: nil,
                repSummary: nil
            )
            let updated = workout.replacing(sets: (workout.sets ?? []) + [localSet])
            let operation = OfflineOperation(
                operationId: idempotencyKey,
                workoutId: workout.workoutId,
                body: .addSet(request),
                createdAt: Date(),
                localSetId: localId
            )
            offlineCapture = try offlineStore.record(operation, activeWorkout: updated)
            _ = apply(.operationQueued(updated))
            isOffline = true
            return true
        } catch {
            _ = apply(.operationFailed(message: message(for: error), ambiguous: false))
            return false
        }
    }

    private func queueForm(
        _ body: FormRatingRequest,
        idempotencyKey: String,
        workout: WorkoutDetail
    ) -> Bool {
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        do {
            let localId = nextLocalFormId(in: workout)
            let localForm = WorkoutForm(
                formId: localId,
                workoutId: workout.workoutId,
                exerciseId: body.exerciseId,
                rating: body.rating,
                note: body.note
            )
            var forms = (workout.forms ?? []).filter {
                $0.exerciseId != body.exerciseId
            }
            forms.append(localForm)
            let updated = workout.replacing(forms: forms)
            let operation = OfflineOperation(
                operationId: idempotencyKey,
                workoutId: workout.workoutId,
                body: .rateForm(body),
                createdAt: Date(),
                localFormId: localId
            )
            offlineCapture = try offlineStore.record(operation, activeWorkout: updated)
            _ = apply(.operationQueued(updated))
            isOffline = true
            return true
        } catch {
            _ = apply(.operationFailed(message: message(for: error), ambiguous: false))
            return false
        }
    }

    private func queueFinish(
        _ body: CompleteWorkoutRequest,
        idempotencyKey: String,
        workout: WorkoutDetail
    ) -> Bool {
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        let request = CompleteWorkoutRequest(
            sessionRpe: body.sessionRpe,
            notRecorded: body.notRecorded,
            durationMin: body.durationMin,
            notes: body.notes,
            endedAt: body.endedAt ?? nowISO()
        )
        do {
            let operation = OfflineOperation(
                operationId: idempotencyKey,
                workoutId: workout.workoutId,
                body: .completeWorkout(request),
                createdAt: Date()
            )
            offlineCapture = try offlineStore.record(operation, activeWorkout: workout)
            isOffline = true
            mutationError = nil
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    private func nextLocalFormId(in workout: WorkoutDetail) -> Int {
        let used = Set((workout.forms ?? []).compactMap(\.formId).filter { $0 < 0 })
        var candidate = -1
        while used.contains(candidate) { candidate -= 1 }
        return candidate
    }

    func syncOfflineCapture() async {
        guard !isSaving, !isSyncingOffline,
              let session, let cached = activeWorkout,
              hasPendingOfflineCapture else { return }
        isSyncingOffline = true
        offlineSyncError = nil
        defer { isSyncingOffline = false }
        do {
            let serverToday = try await client.today(session: session)
            guard let serverActive = serverToday.activeWorkout,
                  serverActive.workoutId == cached.workoutId else {
                offlineSyncError = "The server no longer has this workout active. The local capture was kept; resolve it below."
                return
            }
            for operation in pendingOfflineOperations {
                if operation.state == .expired {
                    if operation.kind == .rateForm {
                        continue
                    }
                    offlineSyncError = "An offline operation is older than the 28-day replay window. Reconcile or discard it before continuing."
                    break
                }
                if operation.state == .failed {
                    continue
                }
                if operation.state == .conflict {
                    break
                }
                if !operation.isReplayable(now: Date()) {
                    offlineCapture = try? offlineStore.updateState(
                        operationId: operation.operationId,
                        state: .expired,
                        error: "Older than the 28-day replay window; reconcile or discard it."
                    )
                    if operation.kind == .rateForm { continue }
                    offlineSyncError = "An offline operation is older than the 28-day replay window. Reconcile or discard it before continuing."
                    break
                }
                _ = try offlineStore.markAttempted(operation.operationId)
                do {
                    switch operation.body {
                    case .addSet(let body):
                        let updated = try await client.addSet(
                            workoutId: operation.workoutId,
                            body: body,
                            session: session,
                            idempotencyKey: operation.operationId,
                            journaling: false
                        )
                        activeWorkout = updated
                        offlineCapture = try offlineStore.remove(operation.operationId)
                        offlineCapture = try offlineStore.setActiveWorkout(updated)
                    case .executionEvents(let events):
                        _ = try await client.submitExecutionEvents(
                            workoutId: operation.workoutId,
                            events: events,
                            session: session,
                            idempotencyKey: operation.operationId
                        )
                        offlineCapture = try offlineStore.remove(operation.operationId)
                    case .rateForm(let body):
                        let updated = try await client.rateForm(
                            workoutId: operation.workoutId,
                            body: body,
                            session: session,
                            idempotencyKey: operation.operationId,
                            journaling: false
                        )
                        activeWorkout = updated
                        offlineCapture = try offlineStore.remove(operation.operationId)
                        offlineCapture = try offlineStore.setActiveWorkout(updated)
                    case .completeWorkout(let body):
                        _ = try await client.completeWorkout(
                            workoutId: operation.workoutId,
                            body: body,
                            session: session,
                            idempotencyKey: operation.operationId,
                            journaling: false
                        )
                        _ = try? offlineStore.remove(operation.operationId)
                        offlineCapture = try? offlineStore.setActiveWorkout(nil)
                        activeWorkout = nil
                        if hasPendingOfflineCapture {
                            offlineSyncError = "The workout finished on the server, but some local operations still need attention."
                        } else {
                            try? offlineStore.clear()
                            offlineCapture = try? offlineStore.load()
                        }
                        await refresh()
                        await loadHistory(reset: true)
                        return
                    }
                } catch {
                    if error is APIError, !shouldQueueOffline(error) {
                        if operation.kind == .rateForm {
                            offlineCapture = try? offlineStore.updateState(
                                operationId: operation.operationId,
                                state: .failed,
                                error: message(for: error)
                            )
                            continue
                        }
                        offlineCapture = try? offlineStore.updateState(
                            operationId: operation.operationId,
                            state: .conflict,
                            error: message(for: error)
                        )
                        offlineSyncError = message(for: error)
                        break
                    }
                    _ = try? offlineStore.updateState(
                        operationId: operation.operationId,
                        state: .pending,
                        error: message(for: error)
                    )
                    offlineCapture = try? offlineStore.load()
                    isOffline = true
                    offlineSyncError = message(for: error)
                    scheduleOfflineRetry()
                    break
                }
            }
            offlineCapture = try? offlineStore.load()
            if !hasPendingOfflineCapture {
                offlineRetryAttempt = 0
                offlineRetryTask?.cancel()
                isOffline = false
                offlineSyncError = nil
            } else if offlineSyncError == nil {
                isOffline = false
            }
        } catch {
            isOffline = true
            offlineSyncError = message(for: error)
        }
    }

    func retryOfflineOperation(_ operationId: String) async -> Bool {
        guard pendingOfflineOperations.first(where: {
            $0.operationId == operationId
        })?.state != .expired else {
            mutationError = "Expired offline work cannot be replayed; reconcile or discard it."
            return false
        }
        do {
            offlineCapture = try offlineStore.updateState(
                operationId: operationId,
                state: .pending,
                error: nil
            )
            offlineSyncError = nil
            await syncOfflineCapture()
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    private func scheduleOfflineRetry() {
        guard hasPendingOfflineCapture, offlineRetryAttempt < 4 else { return }
        let delay = [2, 5, 10, 30][offlineRetryAttempt]
        offlineRetryAttempt += 1
        offlineRetryTask?.cancel()
        offlineRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncOfflineCapture()
        }
    }

    func discardOfflineOperation(_ operationId: String) async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.operationId == operationId
        }) else { return false }
        do {
            var updated = activeWorkout
            if let localSetId = operation.localSetId {
                updated = updated?.replacing(sets: (updated?.sets ?? []).filter {
                    $0.setId != localSetId
                })
            }
            if let localFormId = operation.localFormId {
                updated = updated?.replacing(forms: (updated?.forms ?? []).filter {
                    $0.formId != localFormId
                })
            }
            _ = try offlineStore.remove(operationId)
            if let updated {
                offlineCapture = try offlineStore.setActiveWorkout(updated)
                activeWorkout = updated
            } else {
                offlineCapture = try offlineStore.load()
            }
            if !hasPendingOfflineCapture {
                isOffline = false
                offlineSyncError = nil
            }
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    func discardAllOfflineCapture() async -> Bool {
        do {
            try offlineStore.clear()
            offlineCapture = try offlineStore.load()
            activeWorkout = nil
            offlineSyncError = nil
            isOffline = false
            await refresh()
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    func cancelOfflineOperation(_ operationId: String) async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.operationId == operationId
        }), operation.isCancellable else {
            mutationError = "Only unsent offline work can be cancelled."
            return false
        }
        do {
            var updated = activeWorkout
            if let localSetId = operation.localSetId {
                updated = updated?.replacing(sets: (updated?.sets ?? []).filter {
                    $0.setId != localSetId
                })
            }
            if let localFormId = operation.localFormId {
                updated = updated?.replacing(forms: (updated?.forms ?? []).filter {
                    $0.formId != localFormId
                })
            }
            _ = try offlineStore.cancel(operationId)
            if let updated {
                offlineCapture = try offlineStore.setActiveWorkout(updated)
                activeWorkout = updated
            } else {
                offlineCapture = try offlineStore.load()
            }
            if !hasPendingOfflineCapture { isOffline = false }
            mutationError = nil
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    func cancelOfflineSet(localSetId: Int) async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.localSetId == localSetId
        }) else { return false }
        return await cancelOfflineOperation(operation.operationId)
    }

    func cancelOfflineFinish() async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.kind == .completeWorkout
        }) else { return false }
        return await cancelOfflineOperation(operation.operationId)
    }

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
        try? offlineStore.clear()
        offlineCapture = try? offlineStore.load()
        isOffline = false
        exerciseCatalogue = []
        isLoadingExerciseCatalogue = false
        exerciseCatalogueError = nil
        exerciseDetail = nil
        isLoadingExerciseDetail = false
        exerciseDetailError = nil
        exerciseHistorySessions = []
        exerciseHistoryIncluded = []
        exerciseHistoryTotal = 0
        exerciseHistoryHasMore = false
        isLoadingExerciseHistory = false
        exerciseHistoryError = nil
        exerciseHistoryExerciseId = nil
        exerciseDetailCache = [:]
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
        healthKitRefreshError = nil
        healthKitOperation = OperationKey<HealthKitReadinessRequest>()
        healthKitFollowUp = false
        pairedServerURL = store.serverURL
        phase = .pairing
        errorMessage = nil
        pairingError = message
    }

    private func handleMutation(_ error: Error) {
        if let api = error as? APIError, api.isAuthenticationFailure {
            _ = apply(.mutationErrorCleared)
            forgetLocally(message: api.errorDescription)
        } else {
            _ = apply(.operationFailed(
                message: message(for: error),
                ambiguous: Self.isAmbiguous(error)
            ))
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
