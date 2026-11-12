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

    private let credentialStore: WatchCredentialStore
    private let engine: WatchExecutionEngine
    private let anchor: WatchLivenessAnchor
    private let onCredentialsMissing: @MainActor () -> Void
    private var retryTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var draftTask: Task<Void, Never>?
    private var draftLoad: Double?
    private var draftReps: Int?

    init(
        store: WatchCredentialStore = WatchCredentialStore(),
        anchor: WatchLivenessAnchor? = nil,
        onCredentialsMissing: @escaping @MainActor () -> Void
    ) {
        self.credentialStore = store
        self.anchor = anchor ?? WatchHealthKitAnchor()
        self.onCredentialsMissing = onCredentialsMissing
        self.engine = WatchExecutionEngine(
            client: IOSAPIClient(),
            store: OfflineCaptureStore(fileURL: Self.recordFileURL)
        )
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
            if engine.phase == .active || engine.phase == .finishing {
                await beginLivenessIfNeeded()
                await reconcileNow()
            }
        }
    }

    func sceneBecameActive() async {
        guard engine.phase == .active || engine.phase == .finishing else { return }
        await beginLivenessIfNeeded()
        await reconcileNow()
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
        do {
            try await anchor.begin(at: Date())
            liveness.started()
        } catch {
            liveness.failed((error as? LocalizedError)?.errorDescription)
            lastError = LivenessError.unavailable.errorDescription
            return
        }
        let started = await engine.start(issuedPlanID: issuedPlanID, session: session)
        if !started {
            await endLiveness()
        }
        sync()
    }

    // MARK: - Sets and rest

    func logSet(loadKg: Double?, reps: Int, rir: Int?) async {
        guard let session = currentSession(), let item = engine.selectedItem else { return }
        let itemIndex = item.orderIndex ?? 0
        let entry = WatchExecutionEngine.SetEntry(
            exerciseId: item.exerciseId ?? "",
            planItemIndex: itemIndex,
            setIndex: engine.setsDone(planItemIndex: itemIndex) + 1,
            loadKg: loadKg,
            reps: reps,
            rir: rir
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
        await endLiveness()
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
        isOffline = engine.network == .offline
        lastError = engine.lastError
    }
}
