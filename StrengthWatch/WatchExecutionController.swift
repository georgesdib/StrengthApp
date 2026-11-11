import Combine
import Foundation
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
    @Published private(set) var currentItem: PrescriptionItem?
    @Published private(set) var lastError: String?
    @Published private(set) var isOffline = false
    @Published private(set) var isWorking = false
    @Published private(set) var authorization: LivenessAuthorization = .notDetermined
    @Published private(set) var canUndo = false
    @Published private(set) var activeSet: ActiveSet?

    private let credentialStore: WatchCredentialStore
    private let engine: WatchExecutionEngine
    private let anchor: WatchLivenessAnchor
    private let onCredentialsMissing: @MainActor () -> Void
    private var retryTask: Task<Void, Never>?
    private var livenessStarted = false

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
        Task {
            authorization = await anchor.authorizationStatus()
            if engine.phase == .active || engine.phase == .finishing {
                await beginLivenessIfNeeded()
            }
        }
    }

    func sceneBecameActive() async {
        guard engine.phase == .active || engine.phase == .finishing else { return }
        await beginLivenessIfNeeded()
        await flushNow()
    }

    func sceneWillResign() {
        retryTask?.cancel()
        retryTask = nil
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
            livenessStarted = true
        } catch {
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
        guard let session = currentSession(), let item = engine.currentItem else { return }
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
        let stop = await engine.logSet(entry, session: session)
        if engine.phase == .active, let seconds = item.restS, seconds > 0 {
            try? engine.startRest(seconds: seconds, planItemIndex: item.orderIndex)
        }
        await handle(stop)
        sync()
    }

    func undoLastSet() {
        guard engine.undoLastPendingSet() else { return }
        sync()
    }

    func completedSetCount(for item: PrescriptionItem) -> Int {
        engine.setsDone(planItemIndex: item.orderIndex ?? 0)
    }

    /// Explicitly marks that the lifter began a set, so its start time is observed rather than
    /// inferred. Logging without it is still allowed and simply records no start event.
    func beginSet() {
        do {
            try engine.beginSet()
        } catch {
            lastError = "The set could not be started on the watch."
        }
        sync()
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

    private func beginLivenessIfNeeded() async {
        guard !livenessStarted else { return }
        let status = await anchor.authorizationStatus()
        authorization = status
        guard status == .authorized else { return }
        let startedAt = engine.sessionRecord?.startedAt ?? Date()
        try? await anchor.begin(at: startedAt)
        livenessStarted = true
    }

    private func endLiveness() async {
        guard livenessStarted else { return }
        await anchor.end(at: Date())
        livenessStarted = false
    }

    private func sync() {
        phase = engine.phase
        workout = engine.workout
        rest = engine.sessionRecord?.rest
        pendingCount = engine.pendingCount
        completedSetCount = engine.completedSetCount
        currentItem = engine.currentItem
        canUndo = engine.canUndoLastSet
        activeSet = engine.activeSet
        isOffline = engine.network == .offline
        lastError = engine.lastError
    }
}
