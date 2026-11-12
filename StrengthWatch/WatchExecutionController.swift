import Combine
import Foundation
import Network
import StrengthCore

/// Wires the tested execution engine to the watch UI, HealthKit liveness and the credential
/// store. All rule-bearing logic stays in StrengthCore; this class only sequences calls, maps
/// failures to UI state and schedules retries.
@MainActor
final class WatchExecutionController: ObservableObject {
    @Published private(set) var phase: WatchExecutionPhase = .ready
    @Published private(set) var workout: WorkoutDetail?
    @Published private(set) var rest: RestInterval?
    @Published private(set) var pendingCount = 0
    @Published private(set) var completedSetCount = 0
    @Published private(set) var selectedItem: PrescriptionItem?
    @Published private(set) var lastError: String?
    @Published private(set) var isOffline = false
    @Published private(set) var isWorking = false
    @Published private(set) var authorization: LivenessAuthorization = .notDetermined
    @Published private(set) var canUndo = false
    @Published private(set) var activeSet: ActiveSet?
    @Published private(set) var exerciseItemIndex: Int?
    @Published private(set) var liveness = WatchLivenessPolicy()
    @Published private(set) var planUpdated = false
    @Published private(set) var offPlanNoted = false
    @Published private(set) var canLeaveExercise = true
    @Published private(set) var heartRate: Int?
    @Published private(set) var healthKitState: HealthKitSaveState?
    @Published private(set) var healthKitNoticeDismissed = false
    @Published private(set) var healthKitFailure: String?
    @Published private(set) var effortState: EffortDeliveryState?
    @Published private(set) var tonnageKg = 0.0
    @Published private(set) var isStale = false

    private let credentialStore: WatchCredentialStore
    private let engine: WatchExecutionEngine
    private let anchor: WatchLivenessAnchor
    private let healthRecorder: WatchHealthKitRecorder?
    private let onCredentialsMissing: @MainActor () -> Void
    private var retryTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var heartRateClearTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var draftTask: Task<Void, Never>?
    private var draftLoad: Double?
    private var draftReps: Int?

    init(
        store: WatchCredentialStore = WatchCredentialStore(),
        anchor: WatchLivenessAnchor? = nil,
        recorder: WatchHealthKitRecorder? = nil,
        onCredentialsMissing: @escaping @MainActor () -> Void
    ) {
        self.credentialStore = store
        self.onCredentialsMissing = onCredentialsMissing
        if let anchor {
            self.anchor = anchor
            self.healthRecorder = recorder
        } else if let recorder {
            self.anchor = recorder
            self.healthRecorder = recorder
        } else {
            let health = WatchHealthKitRecorder()
            self.anchor = health
            self.healthRecorder = health
        }
        self.engine = WatchExecutionEngine(
            client: IOSAPIClient(),
            store: OfflineCaptureStore(fileURL: Self.recordFileURL)
        )
        healthRecorder?.onHeartRate = { [weak self] bpm in
            self?.heartRateUpdated(bpm)
        }
    }

    /// A reading older than the freshness window is no longer "live", so it is cleared rather than
    /// left on screen indefinitely.
    private func heartRateUpdated(_ bpm: Int?) {
        heartRateClearTask?.cancel()
        heartRate = bpm
        guard bpm != nil else { return }
        heartRateClearTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(HeartRateReading.freshness * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.heartRate = nil
        }
    }

    static var recordFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthWatch", isDirectory: true)
            .appendingPathComponent("execution.json")
    }

    // MARK: - Lifecycle

    func load() {
        do {
            try engine.restore()
        } catch {
            lastError = "The saved session could not be read."
        }
        sync()
        startPathMonitor()
        Task {
            authorization = await anchor.authorizationStatus()
            // A finished session must not start a new builder: that builder belongs to this
            // launch, not to the workout being recovered (contract §12.3).
            if engine.phase == .active {
                await beginLivenessIfNeeded()
                await reconcileNow()
            } else if engine.phase == .finishing {
                await reconcileNow()
            }
            if needsHealthKitFinalisation {
                await finalizeHealthKit()
            }
        }
    }

    func sceneBecameActive() async {
        guard engine.phase == .active || engine.phase == .finishing else { return }
        if engine.phase == .active {
            await beginLivenessIfNeeded()
        }
        await reconcileNow()
        if needsHealthKitFinalisation {
            await finalizeHealthKit()
        }
    }

    private var needsHealthKitFinalisation: Bool {
        guard let input = engine.healthKitInput() else { return false }
        return input.state == .pending || input.effortState == .pending
    }

    /// Flushes pending work first, then compares ownership, status and revision with the server.
    func reconcileNow() async {
        guard let session = currentSession() else {
            credentialsMissing()
            return
        }
        isWorking = true
        defer { isWorking = false }
        let stop = await engine.reconcile(session: session)
        await handle(stop)
        sync()
    }

    /// Clears the local record without abandoning the server session (used when the phone owns it
    /// or the workout ended elsewhere).
    func clearLocal() {
        engine.clearLocal()
        sync()
    }

    func sceneWillResign() {
        retryTask?.cancel()
        retryTask = nil
        persistDraft()
    }

    /// Server-adjusted elapsed time for the session screen.
    func elapsed(at date: Date) -> TimeInterval {
        engine.sessionRecord?.elapsedSeconds(at: date) ?? 0
    }

    /// Set duration and rest countdown use the same clock domain as their timestamps.
    func setDuration(at date: Date) -> TimeInterval {
        engine.setDuration(at: date)
    }

    func restRemaining(at date: Date) -> TimeInterval? {
        engine.restRemaining(at: date)
    }

    func restIsComplete(at date: Date) -> Bool {
        engine.restIsComplete(at: date)
    }

    // MARK: - Start

    func start(issuedPlanID: String) async {
        guard let session = currentSession() else {
            credentialsMissing()
            return
        }
        isWorking = true
        defer { isWorking = false }

        var status = await anchor.authorizationStatus()
        if status != .authorized {
            status = await anchor.requestAuthorization()
        }
        authorization = status
        guard status == .authorized else {
            lastError = "Enable Health access on the watch to log here, or log this workout on the iPhone."
            return
        }
        // Start HealthKit in the session's clock domain: one bootstrap call before the start gate.
        let collectionStart: Date
        do {
            let clock = try await engine.serverClock(session: session)
            collectionStart = clock.serverNow(from: Date())
        } catch {
            lastError = "Could not confirm the server clock, so the session was not started."
            return
        }
        do {
            try await anchor.begin(at: collectionStart)
            liveness.started()
        } catch {
            liveness.failed((error as? LocalizedError)?.errorDescription)
            lastError = (error as? LocalizedError)?.errorDescription
                ?? LivenessError.unavailable.errorDescription
            return
        }
        let started = await engine.start(issuedPlanID: issuedPlanID, session: session)
        if !started {
            await endLiveness()
        }
        sync()
    }

    // MARK: - Sets and rest

    func logSet(loadKg: Double?, reps: Int, rir: Int?, velocityMps: Double? = nil) async {
        guard let session = currentSession(), let item = engine.selectedItem else { return }
        let itemIndex = item.orderIndex ?? 0
        let entry = WatchExecutionEngine.SetEntry(
            exerciseId: item.exerciseId ?? "",
            planItemIndex: itemIndex,
            setIndex: engine.setsDone(planItemIndex: itemIndex) + 1,
            loadKg: loadKg,
            reps: reps,
            rir: rir,
            velocityMps: velocityMps
        )
        isWorking = true
        defer { isWorking = false }
        let result = await engine.logSet(entry, session: session)
        // Rest belongs to a set that actually happened: a local storage failure must not start
        // one, while a network failure still does.
        if result.persisted, engine.phase == .active, let seconds = item.restS, seconds > 0 {
            try? engine.startRest(seconds: seconds, planItemIndex: item.orderIndex)
        }
        await handle(result.stop)
        sync()
        // Contract §10.2: refresh after each set, so a plan edit whose nudge was dropped while
        // the watch was unreachable is picked up at this idle point rather than at the next
        // foreground. Only when the flush finished cleanly; offline work stays local.
        if result.persisted, result.stop == .allSent {
            await reconcileNow()
        }
    }

    func undoLastSet() {
        guard engine.undoLastPendingSet() else { return }
        sync()
    }

    func completedSetCount(for item: PrescriptionItem) -> Int {
        engine.setsDone(planItemIndex: item.orderIndex ?? 0)
    }

    var planItems: [PrescriptionItem] {
        engine.planItems
    }

    /// Opens an exercise from the list. Telemetry starts with the first set, not the tap.
    func select(_ item: PrescriptionItem) {
        do {
            try engine.selectItem(item.orderIndex ?? 0)
        } catch {
            lastError = "The exercise could not be opened."
        }
        sync()
    }

    func backToList() {
        do {
            try engine.clearSelection()
        } catch {
            lastError = "The exercise could not be closed."
        }
        sync()
    }

    /// Explicitly marks that the lifter began a set, so its start time is observed rather than
    /// inferred. Logging without it is still allowed and simply records no start event.
    func beginSet(loadKg: Double?, reps: Int?) {
        do {
            try engine.beginSet(loadKg: loadKg, reps: reps)
            draftLoad = loadKg
            draftReps = reps
        } catch {
            lastError = "The set could not be started on the watch."
        }
        sync()
    }

    /// The lifter says this exercise is done. Wasted time before the next exercise is then
    /// visible as the gap between this completion and the next exercise's start.
    func doneWithExercise() {
        do {
            try engine.doneWithExercise()
        } catch {
            lastError = "The exercise could not be marked done."
        }
        sync()
    }

    /// Persists the in-progress adjustments, throttled so the Digital Crown does not write on
    /// every detent. A resign forces the last value immediately.
    func draftChanged(loadKg: Double?, reps: Int?) {
        draftLoad = loadKg
        draftReps = reps
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persistDraft()
        }
    }

    private func persistDraft() {
        draftTask?.cancel()
        draftTask = nil
        guard engine.activeSet != nil else { return }
        try? engine.updateActiveSetDraft(loadKg: draftLoad, reps: draftReps)
    }

    func extendRest(by seconds: Int) {
        try? engine.extendRest(by: seconds)
        sync()
    }

    func endRest() {
        try? engine.endRest()
        sync()
    }

    // MARK: - Finish and discard

    func finish(sessionRpe: Double?) async {
        guard let session = currentSession() else {
            credentialsMissing()
            return
        }
        isWorking = true
        defer { isWorking = false }
        let stop = await engine.finish(sessionRpe: sessionRpe, session: session)
        await handle(stop)
        // The HealthKit save ends the live session itself, so liveness is not ended here.
        await finalizeHealthKit()
        if healthRecorder == nil {
            await endLiveness()
        }
        sync()
    }

    func discard() async {
        guard let session = currentSession() else { return }
        await engine.discard(session: session)
        await endLiveness()
        sync()
    }

    func dismissSummary() {
        engine.clearFinished()
        sync()
    }

    /// Runs the exactly-once save through the finaliser. Automatic attempts continue while
    /// pending; a manual attempt is the explicit Try again.
    /// Single-flight: concurrent callers await the attempt already running, because the
    /// existence query is not a uniqueness constraint in HealthKit.
    func finalizeHealthKit(manual: Bool = false) async {
        if let inFlight = finalizeTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFinalize(manual: manual)
            self.finalizeTask = nil
        }
        finalizeTask = task
        await task.value
    }

    private func performFinalize(manual: Bool) async {
        guard let input = engine.healthKitInput(), let recorder = healthRecorder else { return }
        let outcome = await HealthKitFinalizer.finalize(
            externalUUID: input.sessionUUID,
            startedAt: input.startedAt,
            endedAt: input.endedAt,
            effort: input.effort,
            state: input.state,
            attempts: input.attempts,
            effortState: input.effortState,
            effortAttempts: input.effortAttempts,
            manual: manual,
            recorder: recorder
        )
        engine.applyHealthKitOutcome(outcome)
        if outcome.state != .pending {
            await recorder.endWithoutSaving()
            liveness.reset()
        }
        sync()
    }

    /// Try again on the unsaved notice: one immediate attempt, reusing the same external UUID.
    func retryHealthKit() async {
        await finalizeHealthKit(manual: true)
    }

    func dismissHealthKitNotice() {
        engine.dismissHealthKitNotice()
        sync()
    }

    /// Applies a plan revision pushed by the phone; older payloads and an active set are handled by
    /// the engine, so this only decodes and reports.
    func applyRemotePayload(_ userInfo: [String: Any]) {
        guard let json = userInfo["execution"] as? String,
              let payload = RemoteExecutionPayload.decode(json),
              let session = currentSession() else { return }
        _ = engine.applyRemote(payload, deviceID: session.deviceID)
        sync()
    }

    /// Optional form rating for the exercise just finished, queued and replayed like a set.
    func rateForm(exerciseId: String, rating: Int) async {
        guard let session = currentSession() else { return }
        isWorking = true
        defer { isWorking = false }
        let stop = await engine.rateForm(
            exerciseId: exerciseId, rating: rating, session: session
        )
        await handle(stop)
        sync()
    }

    // MARK: - Flush and retry

    func flushNow() async {
        guard let session = currentSession() else { return }
        guard engine.phase == .active || engine.phase == .finishing else { return }
        engine.retryTriggered()
        let stop = await engine.flush(session: session)
        await handle(stop)
        sync()
    }

    private func handle(_ stop: WatchFlushStop) async {
        switch stop {
        case .credentialsMissing:
            credentialsMissing()
        case .retry(let date):
            scheduleRetry(at: date)
        case .retryWindowSpent:
            lastError = "Offline. Saved on the watch; it will sync when you open the app at home."
        case .conflict(_, let message):
            lastError = message
        case .storage(let message):
            lastError = message
        case .allSent, .nothingToSend:
            lastError = nil
        }
    }

    private func scheduleRetry(at date: Date) {
        retryTask?.cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            await self?.flushNow()
        }
    }

    // MARK: - Private

    private func currentSession() -> IOSSession? {
        guard let stored = credentialStore.stored,
              let token = credentialStore.loadToken(),
              let baseURL = URL(string: stored.homeBaseURL) else { return nil }
        return IOSSession(baseURL: baseURL, token: token, deviceID: stored.deviceID)
    }

    private func credentialsMissing() {
        credentialStore.markCredentialsMissing()
        onCredentialsMissing()
    }

    private func startPathMonitor() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                await self?.pathBecameAvailable()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "strength.watch.path"))
    }

    private func pathBecameAvailable() async {
        guard engine.phase == .active || engine.phase == .finishing else { return }
        await flushNow()
    }

    /// A restored or recovered session asks HealthKit again, but claims liveness only when the
    /// anchor actually started. Otherwise the app is foreground-only and says so (contract §11.2).
    private func beginLivenessIfNeeded() async {
        guard !liveness.isRunning else { return }
        let status = await anchor.authorizationStatus()
        authorization = status
        guard status == .authorized else {
            liveness.authorizationUnavailable()
            return
        }
        do {
            // The resumed segment starts now; the saved workout keeps the original dates in 6.5.
            try await anchor.begin(at: Date())
            liveness.started()
        } catch {
            liveness.failed((error as? LocalizedError)?.errorDescription)
        }
    }

    private func endLiveness() async {
        guard liveness.isRunning else { return }
        await anchor.end(at: Date())
        liveness.reset()
    }

    private func sync() {
        phase = engine.phase
        workout = engine.workout
        rest = engine.sessionRecord?.rest
        pendingCount = engine.pendingCount
        completedSetCount = engine.completedSetCount
        selectedItem = engine.selectedItem
        canUndo = engine.canUndoLastSet
        activeSet = engine.activeSet
        exerciseItemIndex = engine.exerciseItemIndex
        planUpdated = engine.planUpdated
        offPlanNoted = engine.sessionRecord?.offPlanNoted ?? false
        canLeaveExercise = engine.canLeaveExercise
        healthKitState = engine.sessionRecord?.finish?.hkState
        healthKitNoticeDismissed = engine.sessionRecord?.finish?.hkNoticeDismissed ?? false
        healthKitFailure = engine.healthKitFailure
        effortState = engine.sessionRecord?.finish?.effortState
        tonnageKg = engine.tonnageKg
        isStale = engine.isStale
        isOffline = engine.network == .offline
        lastError = engine.lastError
    }
}
