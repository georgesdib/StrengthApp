import Foundation

/// Why the server-side session is no longer writable. The raw server status is never shown to the
/// lifter; the view renders a stable, explicit message for each case.
public enum WatchEndedReason: Equatable, Sendable {
    case completed
    case abandoned
    case unavailable

    public init(status: String) {
        switch status.lowercased() {
        case "completed": self = .completed
        case "abandoned": self = .abandoned
        default: self = .unavailable
        }
    }

    public var title: String {
        switch self {
        case .completed: return "Workout completed elsewhere"
        case .abandoned: return "Workout abandoned elsewhere"
        case .unavailable: return "Workout ended elsewhere"
        }
    }

    public var message: String {
        switch self {
        case .completed:
            return "This workout was completed on another device. The sets recorded on this watch are preserved locally."
        case .abandoned:
            return "This workout was abandoned on another device. The sets recorded on this watch are preserved locally."
        case .unavailable:
            return "This workout is no longer active on the server. The sets recorded on this watch are preserved locally."
        }
    }
}

public enum WatchExecutionPhase: Equatable, Sendable {
    case ready
    case starting
    case active
    case finishing
    case finished
    case abandoned
    /// The phone took ownership; the watch shows the session but cannot write.
    case readOnly
    /// The server completed, abandoned or lost the workout; the snapshot is a preserved record.
    case ended(WatchEndedReason)
}

/// The outcome of one flush pass. The caller decides when to try again; the engine never
/// schedules its own timer.
/// One read-only row on the active-session Plan screen. It carries no action.
public struct WatchPlanRow: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case completed
        case current
        case upcoming
    }

    public let orderIndex: Int
    public let exerciseId: String
    public let plannedSets: Int
    public let completedSets: Int
    public let status: Status

    public init(
        orderIndex: Int,
        exerciseId: String,
        plannedSets: Int,
        completedSets: Int,
        status: Status
    ) {
        self.orderIndex = orderIndex
        self.exerciseId = exerciseId
        self.plannedSets = plannedSets
        self.completedSets = completedSets
        self.status = status
    }

    public var id: Int { orderIndex }
}

public enum WatchFlushStop: Equatable, Sendable {
    case nothingToSend
    case allSent
    case retry(at: Date)
    case retryWindowSpent
    case credentialsMissing
    case conflict(code: String, message: String)
    case storage(String)

    public var isRetryable: Bool {
        if case .retry = self { return true }
        return false
    }
}

extension WatchFlushStop: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nothingToSend: return "nothingToSend"
        case .allSent: return "allSent"
        case .retry(let at): return "retry(at: \(at))"
        case .retryWindowSpent: return "retryWindowSpent"
        case .credentialsMissing: return "credentialsMissing"
        case .conflict(let code, let message): return "conflict(\(code): \(message))"
        case .storage(let message): return "storage(\(message))"
        }
    }
}

/// The watch's execution lifecycle (contract §11).
///
/// Every user action is one atomic local write: the outbox operation, the session record and the
/// telemetry events for that action move together or not at all. Network calls and HealthKit stay
/// outside this type so the rules are testable on the iPhone simulator.
@MainActor
public final class WatchExecutionEngine {
    public struct SetEntry: Equatable, Sendable {
        public var exerciseId: String
        public var planItemIndex: Int?
        public var setIndex: Int
        public var loadKg: Double?
        public var reps: Int
        public var rir: Int?
        /// Optional mean bar velocity for the set (VBT). Descriptive only; it never decides load.
        public var velocityMps: Double?
        /// Optional per-rep velocities, in rep order. Descriptive like the mean.
        public var repVelocities: [RepVelocity]?

        public init(
            exerciseId: String,
            planItemIndex: Int?,
            setIndex: Int,
            loadKg: Double?,
            reps: Int,
            rir: Int?,
            velocityMps: Double? = nil,
            repVelocities: [RepVelocity]? = nil
        ) {
            self.exerciseId = exerciseId
            self.planItemIndex = planItemIndex
            self.setIndex = setIndex
            self.loadKg = loadKg
            self.reps = reps
            self.rir = rir
            self.velocityMps = velocityMps
            self.repVelocities = repVelocities
        }
    }

    /// A local capture result, kept separate from the flush outcome: a set that failed to persist
    /// must not be treated like a set that is merely waiting for the network.
    public struct CaptureResult: Equatable, Sendable {
        public let persisted: Bool
        public let stop: WatchFlushStop

        public init(persisted: Bool, stop: WatchFlushStop) {
            self.persisted = persisted
            self.stop = stop
        }
    }

    public private(set) var phase: WatchExecutionPhase = .ready
    public private(set) var workout: WorkoutDetail?
    public private(set) var sessionRecord: WatchSessionRecord?
    public private(set) var pending: [OfflineOperation] = []
    public private(set) var lastError: String?
    public private(set) var network: HomeNetworkState = .unknown
    public private(set) var nextRetryAt: Date?
    /// A newer plan arrived while the watch was busy; it is applied at the next idle point.
    public private(set) var planUpdated = false
    /// Why the last HealthKit save attempt failed, if it did.
    public private(set) var healthKitFailure: String?
    /// The server considers this session idle (contract §16 idle warning); display only.
    public private(set) var isStale = false

    /// Descriptive tonnage of acknowledged plus queued sets. Not a training decision.
    public var tonnageKg: Double {
        let acknowledged = (workout?.sets ?? []).reduce(0.0) { total, set in
            total + (set.loadKg ?? 0) * Double(set.reps ?? 0)
        }
        let queued = pending.reduce(0.0) { total, operation in
            guard case .addSet(let body) = operation.body else { return total }
            return total + (body.loadKg ?? 0) * Double(body.reps)
        }
        return acknowledged + queued
    }

    private let client: IOSAPIClient
    private let store: OfflineCaptureStore
    private var ladder = RetryLadder()
    private var networkPolicy = HomeNetworkPolicy()
    private var deferredPlan: (revision: Int, plan: PrescriptionPlan)?
    private var flushTask: Task<WatchFlushStop, Never>?
    private let now: () -> Date

    public init(
        client: IOSAPIClient,
        store: OfflineCaptureStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.store = store
        self.now = now
    }

    // MARK: - Derived state

    /// User-facing work only: telemetry batches are durable but are not "pending sets".
    public var pendingCount: Int {
        pending.filter { $0.kind != .executionEvents }.count
    }

    public var pendingEventCount: Int {
        pending.filter { $0.kind == .executionEvents }.count
    }

    public var pendingSetCount: Int {
        pending.filter { $0.kind == .addSet }.count
    }

    public var completedSetCount: Int {
        (workout?.sets?.count ?? 0) + pendingSetCount
    }

    public var planItems: [PrescriptionItem] {
        workout?.plan?.items ?? []
    }

    /// Read-only plan rows for the active-session Plan screen. Reading them never changes the
    /// selection, active set or execution phase, so opening Plan cannot disturb the workout.
    public var planRows: [WatchPlanRow] {
        let current = sessionRecord?.selectedItemIndex
        return planItems.enumerated().map { position, item in
            let identity = item.orderIndex ?? position
            let planned = item.sets ?? 0
            let completed = setsDone(planItemIndex: identity)
            let status: WatchPlanRow.Status
            if identity == current {
                status = .current
            } else if planned > 0, completed >= planned {
                status = .completed
            } else {
                status = .upcoming
            }
            return WatchPlanRow(
                orderIndex: identity,
                exerciseId: item.exerciseId ?? "exercise",
                plannedSets: planned,
                completedSets: completed,
                status: status
            )
        }
    }

    /// The next unfinished item after the current one, falling back to the first unfinished item
    /// when the current exercise is the last one. Read-only; it never changes the selection.
    public var nextPlanItem: PrescriptionItem? {
        let items = planItems
        guard !items.isEmpty else { return nil }
        let current = sessionRecord?.selectedItemIndex
        let start = current.flatMap { index in
            items.firstIndex { ($0.orderIndex ?? -1) == index }.map { $0 + 1 }
        } ?? 0
        let ordered: [PrescriptionItem]
        if start <= 0 || start >= items.count {
            ordered = items
        } else {
            ordered = Array(items[start...]) + Array(items[..<start])
        }
        return ordered.first {
            setsDone(planItemIndex: $0.orderIndex ?? -1) < ($0.sets ?? 0)
        }
    }

    public var activeSet: ActiveSet? {
        sessionRecord?.activeSet
    }

    public var exerciseItemIndex: Int? {
        sessionRecord?.exerciseItemIndex
    }

    /// An exercise is active from its first started set until it is ended, so the list cannot be
    /// re-entered in between.
    public var canLeaveExercise: Bool {
        sessionRecord?.exerciseItemIndex == nil
    }

    /// The exercise the lifter picked from the list. Nothing can be started or logged without
    /// one, which is what keeps every set paired with an exercise.
    public var selectedItem: PrescriptionItem? {
        guard let index = sessionRecord?.selectedItemIndex else { return nil }
        return planItems.first { ($0.orderIndex ?? -1) == index }
    }

    public func plannedSets(for item: PrescriptionItem) -> Int {
        item.sets ?? 0
    }

    /// Picks an exercise. This emits nothing by itself: `exercise_started` belongs to the first
    /// set that actually starts. Leaving a started exercise closes it at that instant.
    public func selectItem(_ itemIndex: Int) throws {
        guard let workout, planItems.contains(where: { ($0.orderIndex ?? -1) == itemIndex }) else {
            return
        }
        // While an exercise is active the lifter stays in it until End exercise.
        if let active = sessionRecord?.exerciseItemIndex, active != itemIndex {
            return
        }
        let stamp = stampedNow()
        try mutate { capture in
            guard var record = capture.session else { return }
            if record.exerciseItemIndex != nil, record.exerciseItemIndex != itemIndex {
                try self.closeExercise(in: &capture, at: stamp, workout: workout)
                record = capture.session ?? record
            }
            record.selectedItemIndex = itemIndex
            capture.session = record
        }
    }

    /// Returns to the exercise list without ending the exercise; the next Start set still counts
    /// for the same exercise if it is selected again.
    public func clearSelection() throws {
        guard canLeaveExercise else { return }
        guard let workout, sessionRecord?.selectedItemIndex != nil else { return }
        let stamp = stampedNow()
        try mutate { capture in
            guard var record = capture.session else { return }
            record.selectedItemIndex = nil
            capture.session = record
            try self.closeExercise(in: &capture, at: stamp, workout: workout)
        }
    }

    public func setsDone(planItemIndex: Int) -> Int {
        let acknowledged = workout?.sets?.filter {
            ($0.planItemIndex ?? -1) == planItemIndex
        }.count ?? 0
        let queued = pending.filter { operation in
            guard case .addSet(let body) = operation.body else { return false }
            return body.planItemIndex == planItemIndex
        }.count
        return acknowledged + queued
    }

    /// Now in the session's clock domain (server-adjusted when the offset is known).
    public func serverNow(_ local: Date = Date()) -> Date {
        sessionRecord?.serverNow(at: local) ?? local
    }

    public func setDuration(at local: Date) -> TimeInterval {
        guard let record = sessionRecord, let active = record.activeSet else { return 0 }
        return record.setDuration(setStartedAt: active.startedAt, at: local)
    }

    public func restRemaining(at local: Date) -> TimeInterval? {
        sessionRecord?.restRemaining(at: local)
    }

    public func restIsComplete(at local: Date) -> Bool {
        sessionRecord?.restIsComplete(at: local) ?? false
    }

    public var canUndoLastSet: Bool {
        pending.contains { $0.kind == .addSet && $0.attemptedAt == nil }
    }

    public var canDiscard: Bool {
        workout != nil && (phase == .active || phase == .finishing)
    }

    // MARK: - Restore

    /// Reconciles with the server (contract §10.3/§11.5): flush pending work, then compare
    /// ownership and status. A newer plan is applied only at an idle point.
    @discardableResult
    public func reconcile(session: IOSSession) async -> WatchFlushStop {
        guard let workoutId = workout?.workoutId else { return .nothingToSend }
        switch phase {
        case .active, .finishing:
            let stop = await flush(session: session)
            // A failed flush leaves the local queue authoritative: fetching now could apply a
            // snapshot that does not yet contain the queued work. Only a clean flush may proceed.
            switch stop {
            case .allSent, .nothingToSend:
                break
            default:
                return stop
            }
        case .readOnly, .ended:
            break
        default:
            return .nothingToSend
        }
        do {
            let envelope = try await client.executionAnalytics(
                workoutId: workoutId, session: session
            )
            return apply(envelope, session: session)
        } catch let api as APIError {
            switch api {
            case .unauthorized, .forbidden:
                return .credentialsMissing
            case .server(let status, let code, _, _, _)
                where status == 404 || code == "workout_not_found":
                phase = .ended(.unavailable)
                return .nothingToSend
            default:
                return transient(api)
            }
        } catch {
            return transient(error)
        }
    }

    /// Applies a phone-pushed execution payload: newer only, idle point only, and never when the
    /// phone owns the session (contract §10.2/§10.5).
    @discardableResult
    public func applyRemote(_ payload: RemoteExecutionPayload, deviceID: String?) -> Bool {
        guard let workout, payload.workoutId == workout.workoutId else { return false }
        if let owner = payload.ownerDeviceId, !owner.isEmpty,
           let deviceID, !deviceID.isEmpty, owner != deviceID {
            phase = .readOnly
            return true
        }
        guard payload.planRevision > (sessionRecord?.planRevision ?? 0) else { return false }
        guard activeSet == nil else {
            deferredPlan = (payload.planRevision, payload.plan)
            planUpdated = true
            return true
        }
        apply(plan: payload.plan, revision: payload.planRevision)
        return true
    }

    /// Records a form rating for the exercise just finished, queued like any other capture.
    @discardableResult
    public func rateForm(
        exerciseId: String,
        rating: Int,
        session: IOSSession
    ) async -> WatchFlushStop {
        guard phase == .active, let workout, (1...5).contains(rating) else {
            return .conflict(code: "not_active", message: "This session cannot take a rating.")
        }
        let operation = OfflineOperation(
            operationId: UUID().uuidString.lowercased(),
            workoutId: workout.workoutId,
            body: .rateForm(FormRatingRequest(
                exerciseId: exerciseId, rating: rating, note: nil
            )),
            createdAt: now()
        )
        do {
            try mutate { capture in
                try self.appendOperation(operation, to: &capture)
            }
        } catch {
            return .storage(message(for: error))
        }
        return await flush(session: session)
    }

    /// Drops the local record without touching the server. Used when the session belongs to the
    /// phone or has already ended.
    public func clearLocal() {
        try? store.clear()
        workout = nil
        sessionRecord = nil
        pending = []
        nextRetryAt = nil
        lastError = nil
        phase = .ready
    }

    private func apply(
        _ envelope: ExecutionAnalyticsResponse,
        session: IOSSession
    ) -> WatchFlushStop {
        guard envelope.status == "in_progress" else {
            phase = .ended(WatchEndedReason(status: envelope.status))
            return .nothingToSend
        }
        // Missing ownership is never permission to write (fail closed).
        guard let owner = envelope.ownerDeviceId, !owner.isEmpty else {
            phase = .readOnly
            lastError = "Ownership could not be confirmed, so the watch is read-only."
            return .nothingToSend
        }
        guard let device = session.deviceID, !device.isEmpty else {
            phase = .readOnly
            lastError = "This watch's device identity is missing, so the watch is read-only."
            return .nothingToSend
        }
        guard owner == device else {
            phase = .readOnly
            return .nothingToSend
        }
        // Confirmed ownership restores writing after a read-only or reconciliation-required state.
        if case .readOnly = phase {
            phase = .active
            lastError = nil
        }
        isStale = envelope.stale ?? false
        applyRevisionIfNeeded(envelope)
        markOnline(session)
        return .allSent
    }

    private func applyRevisionIfNeeded(_ envelope: ExecutionAnalyticsResponse) {
        guard let revision = envelope.planRevision,
              let plan = envelope.plan,
              revision > (sessionRecord?.planRevision ?? 0) else { return }
        guard activeSet == nil else {
            deferredPlan = (revision, plan)
            planUpdated = true
            return
        }
        apply(plan: plan, revision: revision)
    }

    /// Applies a deferred revision once the watch is idle again (contract §10.5).
    private func applyDeferredPlanIfIdle() {
        guard let deferred = deferredPlan, activeSet == nil else { return }
        deferredPlan = nil
        apply(plan: deferred.plan, revision: deferred.revision)
    }

    private func apply(plan: PrescriptionPlan, revision: Int) {
        guard let workout, var record = sessionRecord else { return }
        let updated = WorkoutDetail(
            workoutId: workout.workoutId,
            prescriptionId: workout.prescriptionId,
            forDate: workout.forDate,
            sessionType: workout.sessionType,
            status: workout.status,
            plan: plan,
            sets: workout.sets,
            forms: workout.forms,
            elapsedSeconds: workout.elapsedSeconds,
            sessionRpe: workout.sessionRpe,
            startedAt: workout.startedAt,
            ownerDeviceId: workout.ownerDeviceId,
            planRevision: revision,
            lastActivityAt: workout.lastActivityAt
        )
        record.planRevision = revision
        if let selected = record.selectedItemIndex,
           !plan.items.contains(where: { ($0.orderIndex ?? -1) == selected }) {
            record.selectedItemIndex = nil
        }
        do {
            try mutate { capture in
                capture.activeWorkout = updated
                capture.session = record
            }
            planUpdated = false
        } catch {
            planUpdated = true
        }
    }

    /// Relaunches from the durable record without contacting the server (contract §11.5 is 6.4).
    public func restore() throws {
        let capture = try store.load()
        apply(capture)
        guard capture.session != nil, capture.activeWorkout != nil else {
            phase = .ready
            return
        }
        if let finish = capture.session?.finish {
            phase = finish.serverAcked ? .finished : .finishing
        } else {
            phase = .active
        }
    }

    // MARK: - Start

    /// The server-adjusted clock used to start HealthKit collection, so the live workout's start
    /// and its server-derived end share one domain (contract §8).
    public func serverClock(session: IOSSession) async throws -> ServerClock {
        let receivedAt = now()
        let bootstrap = try await client.bootstrap(session: session)
        guard let serverTime = ServerClock.parse(bootstrap.serverTime) else {
            throw APIError.decoding
        }
        let clock = ServerClock(serverTime: serverTime, receivedAt: receivedAt)
        guard clock.isPlausible else { throw APIError.decoding }
        return clock
    }

    @discardableResult
    public func start(issuedPlanID: String, session: IOSSession) async -> Bool {
        guard !issuedPlanID.isEmpty else {
            lastError = "This plan cannot be started on the watch."
            return false
        }
        phase = .starting
        lastError = nil
        let receivedAt = now()
        do {
            let detail = try await client.startWorkout(
                issuedPlanId: issuedPlanID,
                session: session,
                idempotencyKey: OperationID.derived("start:" + issuedPlanID)
            )
            // A derived offset larger than a day means the watch clock is wrong, not the server:
            // applying it would push every capture outside the replay window and the workout.
            let clock = detail.startedAt
                .flatMap { ServerClock(serverTimestamp: $0, receivedAt: receivedAt) }
                .flatMap { $0.isPlausible ? $0 : nil }
            let record = WatchSessionRecord(
                sessionUUID: UUID().uuidString.lowercased(),
                startedAt: clock?.serverNow(from: receivedAt) ?? receivedAt,
                planRevision: 0,
                clockOffsetSeconds: clock?.offset
            )
            try mutate { capture in
                if !capture.operations.isEmpty,
                   capture.activeWorkout?.workoutId != detail.workoutId {
                    throw OfflineCaptureStoreError.invalidOperation(
                        "Resolve queued work before starting a different workout."
                    )
                }
                capture.session = record
                capture.activeWorkout = detail
            }
            if let owner = detail.ownerDeviceId,
               let device = session.deviceID,
               !owner.isEmpty,
               owner == device {
                phase = .active
            } else {
                // The session exists server-side, but this watch cannot prove it may write.
                phase = .readOnly
                lastError = "Ownership could not be confirmed, so logging is disabled on this watch."
            }
            nextRetryAt = nil
            ladder.succeeded()
            markOnline(session)
            return true
        } catch {
            phase = .ready
            lastError = message(for: error)
            markOfflineIfTransport(error)
            return false
        }
    }

    // MARK: - Sets

    /// The lifter began a set. This is an explicit observation, never inferred from a screen.
    public func beginSet(loadKg: Double? = nil, reps: Int? = nil) throws {
        guard phase == .active, let item = selectedItem, let workout else { return }
        let itemIndex = item.orderIndex ?? 0
        let setIndex = setsDone(planItemIndex: itemIndex) + 1
        let stamp = stampedNow()
        let token = UUID().uuidString.lowercased()
        try mutate { capture in
            try self.closeRest(in: &capture, at: stamp, workout: workout)
            try self.touchExercise(in: &capture, itemIndex: itemIndex, at: stamp, workout: workout)
            guard var record = capture.session else { return }
            record.activeSet = ActiveSet(
                localSetID: token,
                planItemIndex: itemIndex,
                setIndex: setIndex,
                startedAt: stamp,
                loadKg: loadKg,
                reps: reps
            )
            capture.session = record
            try self.append([ExecutionEvent(
                eventId: UUID().uuidString.lowercased(),
                eventType: .setStarted,
                occurredAt: ServerClock.encodedISO(stamp),
                planItemIndex: itemIndex,
                localSetId: token,
                payload: ["set_index": .number(Double(setIndex))]
            )], to: &capture, workout: workout)
        }
    }

    /// The lifter says the current exercise is finished. Nothing is sent when no exercise was
    /// started, because there would be no start to pair with.
    public func doneWithExercise() throws {
        guard let workout else { return }
        let stamp = stampedNow()
        try mutate { capture in
            try self.closeRest(in: &capture, at: stamp, workout: workout)
            try self.closeExercise(in: &capture, at: stamp, workout: workout)
            if let active = capture.session?.activeSet {
                self.dropEvents(localSetID: active.localSetID, from: &capture)
            }
            guard var record = capture.session else { return }
            record.selectedItemIndex = nil
            record.activeSet = nil
            capture.session = record
        }
        applyDeferredPlanIfIdle()
    }

    // MARK: - HealthKit finalisation

    public struct HealthKitInput: Equatable, Sendable {
        public let sessionUUID: String
        public let startedAt: Date
        public let endedAt: Date
        public let effort: Double?
        public let state: HealthKitSaveState
        public let attempts: Int
        public let dismissed: Bool
        public let effortState: EffortDeliveryState?
        public let effortAttempts: Int?
    }

    public func healthKitInput() -> HealthKitInput? {
        guard let record = sessionRecord, let finish = record.finish else { return nil }
        return HealthKitInput(
            sessionUUID: record.sessionUUID,
            startedAt: record.startedAt,
            endedAt: finish.endedAt,
            effort: finish.sessionRpe,
            state: finish.hkState,
            attempts: finish.hkAttempts ?? 0,
            dismissed: finish.hkNoticeDismissed ?? false,
            effortState: finish.effortState,
            effortAttempts: finish.effortAttempts
        )
    }

    public func applyHealthKitOutcome(_ outcome: HealthKitFinalizationOutcome) {
        guard var record = sessionRecord, var finish = record.finish else { return }
        finish.hkState = outcome.state
        finish.hkAttempts = outcome.attempts
        if let effortState = outcome.effortState {
            finish.effortState = effortState
        }
        if let effortAttempts = outcome.effortAttempts {
            finish.effortAttempts = effortAttempts
        }
        record.finish = finish
        sessionRecord = record
        healthKitFailure = outcome.state == .unsaved ? outcome.failure : nil
        if let updated = try? store.setSession(record) {
            apply(updated)
        }
    }

    /// Stops showing the unsaved notice. The unsaved state itself is kept.
    public func dismissHealthKitNotice() {
        guard var record = sessionRecord, var finish = record.finish else { return }
        finish.hkNoticeDismissed = true
        record.finish = finish
        sessionRecord = record
        if let updated = try? store.setSession(record) {
            apply(updated)
        }
    }

    /// Cancels the set in progress without recording one. Its start event is dropped, because a
    /// set that never happened leaves no trace.
    public func cancelActiveSet() throws {
        guard sessionRecord?.activeSet != nil else { return }
        try mutate { capture in
            if let active = capture.session?.activeSet {
                self.dropEvents(localSetID: active.localSetID, from: &capture)
            }
            guard var record = capture.session else { return }
            record.activeSet = nil
            capture.session = record
        }
        applyDeferredPlanIfIdle()
    }

    /// Ends an open rest at this instant, because starting or logging the next set is what
    /// really ends recovery (contract §13; owner decision 2026-11-11).
    public func endRest() throws {
        guard let workout else { return }
        let stamp = stampedNow()
        try mutate { capture in
            try self.closeRest(in: &capture, at: stamp, workout: workout)
        }
        applyDeferredPlanIfIdle()
    }

    /// Persists the lifter's in-progress adjustments so a termination before logging loses
    /// nothing.
    public func updateActiveSetDraft(loadKg: Double?, reps: Int?) throws {
        try mutate { capture in
            guard var record = capture.session, var active = record.activeSet else { return }
            active.loadKg = loadKg
            active.reps = reps
            record.activeSet = active
            capture.session = record
        }
    }

    /// Persists the set before any request and then attempts one flush pass. An open rest is
    /// closed first, at the same instant, so every rest has one deliberate terminal event.
    @discardableResult
    public func logSet(_ entry: SetEntry, session: IOSSession) async -> CaptureResult {
        guard phase == .active else {
            return CaptureResult(
                persisted: false,
                stop: .conflict(code: "not_active", message: "This session cannot take sets.")
            )
        }
        guard let workout else {
            return CaptureResult(
                persisted: false,
                stop: .conflict(code: "no_workout", message: "There is no active workout.")
            )
        }
        let stamp = stampedNow()
        let token = sessionRecord?.activeSet?.localSetID ?? UUID().uuidString.lowercased()
        let localSetID: Int
        do {
            localSetID = try store.nextLocalSetId()
        } catch {
            return CaptureResult(persisted: false, stop: .storage(message(for: error)))
        }
        let request = AddSetRequest(
            exerciseId: entry.exerciseId,
            loadKg: entry.loadKg,
            reps: entry.reps,
            rir: entry.rir,
            velocityMps: entry.velocityMps,
            setIndex: entry.setIndex,
            planItemIndex: entry.planItemIndex,
            repVelocities: entry.repVelocities,
            performedAt: ServerClock.encodedISO(stamp)
        )
        do {
            try mutate { capture in
                try self.closeRest(in: &capture, at: stamp, workout: workout)
                if let planItemIndex = entry.planItemIndex {
                    try self.touchExercise(
                        in: &capture, itemIndex: planItemIndex, at: stamp, workout: workout
                    )
                }
                if var record = capture.session {
                    record.activeSet = nil
                    capture.session = record
                }
                try self.appendOperation(OfflineOperation(
                    operationId: token,
                    workoutId: workout.workoutId,
                    body: .addSet(request),
                    createdAt: stamp,
                    localSetId: localSetID
                ), to: &capture)
                try self.append([ExecutionEvent(
                    eventId: UUID().uuidString.lowercased(),
                    eventType: .setCompleted,
                    occurredAt: ServerClock.encodedISO(stamp),
                    planItemIndex: entry.planItemIndex,
                    localSetId: token,
                    payload: ["set_index": .number(Double(entry.setIndex))]
                )], to: &capture, workout: workout)
            }
        } catch {
            lastError = message(for: error)
            return CaptureResult(persisted: false, stop: .storage(message(for: error)))
        }
        let stop = await flush(session: session)
        applyDeferredPlanIfIdle()
        return CaptureResult(persisted: true, stop: stop)
    }

    /// Removes the newest set that has never been attempted, together with its queued events.
    /// Once a request may have reached the server the set is not cancellable locally (6.4 owns
    /// post-sync correction).
    @discardableResult
    public func undoLastPendingSet() -> Bool {
        guard let operation = pending.last(where: {
            $0.kind == .addSet && $0.attemptedAt == nil
        }) else { return false }
        do {
            try mutate { capture in
                capture.operations.removeAll { $0.operationId == operation.operationId }
                self.dropEvents(localSetID: operation.operationId, from: &capture)
            }
        } catch {
            return false
        }
        applyDeferredPlanIfIdle()
        return true
    }

    // MARK: - Rest

    public func startRest(seconds: Int, planItemIndex: Int? = nil) throws {
        guard seconds > 0, let workout else { return }
        let stamp = stampedNow()
        try mutate { capture in
            guard var record = capture.session else { return }
            record.rest = RestInterval(
                startedAt: stamp,
                prescribedSeconds: seconds,
                planItemIndex: planItemIndex
            )
            capture.session = record
            try self.append([ExecutionEvent(
                eventId: UUID().uuidString.lowercased(),
                eventType: .restStarted,
                occurredAt: ServerClock.encodedISO(stamp),
                planItemIndex: planItemIndex,
                payload: ["prescribed_rest_s": .number(Double(seconds))]
            )], to: &capture, workout: workout)
        }
    }

    public func extendRest(by seconds: Int) throws {
        guard seconds > 0, let workout else { return }
        let stamp = stampedNow()
        try mutate { capture in
            guard var record = capture.session, var rest = record.rest, rest.isOpen else { return }
            rest.extend(by: seconds)
            record.rest = rest
            capture.session = record
            try self.append([ExecutionEvent(
                eventId: UUID().uuidString.lowercased(),
                eventType: .restExtended,
                occurredAt: ServerClock.encodedISO(stamp),
                planItemIndex: rest.planItemIndex,
                payload: ["added_s": .number(Double(seconds))]
            )], to: &capture, workout: workout)
        }
    }

    // MARK: - Finish

    @discardableResult
    public func finish(sessionRpe: Double?, session: IOSSession) async -> WatchFlushStop {
        guard phase == .active || phase == .finishing, sessionRecord != nil else {
            return .conflict(code: "not_active", message: "This session cannot be finished.")
        }
        guard let workoutId = workout?.workoutId, let workout else {
            return .conflict(code: "no_workout", message: "There is no active workout.")
        }
        let endedAt = stampedNow()
        let operation = OfflineOperation(
            // The server requires a UUID idempotency key. The session UUID is stable across
            // retries of this one finish, so a lost response still deduplicates.
            operationId: sessionRecord?.sessionUUID ?? workoutId,
            workoutId: workoutId,
            body: .completeWorkout(CompleteWorkoutRequest(
                sessionRpe: sessionRpe,
                notRecorded: sessionRpe == nil,
                durationMin: nil,
                notes: nil,
                endedAt: ServerClock.encodedISO(endedAt),
                productivity: nil
            )),
            createdAt: endedAt
        )
        do {
            // Finishing during a rest closes it; finishing during an unlogged set drops the start
            // event for a set that never happened. Everything lands in one write.
            try mutate { capture in
                try self.closeRest(in: &capture, at: endedAt, workout: workout)
                try self.closeExercise(in: &capture, at: endedAt, workout: workout)
                if let active = capture.session?.activeSet {
                    self.dropEvents(localSetID: active.localSetID, from: &capture)
                }
                guard var record = capture.session else { return }
                record.finish = FinishIntent(endedAt: endedAt, sessionRpe: sessionRpe)
                record.activeSet = nil
                record.selectedItemIndex = nil
                capture.session = record
                if !capture.operations.contains(where: { $0.operationId == operation.operationId }) {
                    try self.appendOperation(operation, to: &capture)
                }
            }
        } catch {
            lastError = message(for: error)
            return .storage(message(for: error))
        }
        phase = .finishing
        return await flush(session: session)
    }

    // MARK: - Discard

    /// Abandons server-side when reachable and always clears the local record. Offline, the
    /// server session is left to the idle abandonment window (contract §9).
    public func discard(session: IOSSession) async {
        if let workout, workout.status == "in_progress" {
            _ = try? await client.abandonWorkout(
                workoutId: workout.workoutId,
                session: session,
                idempotencyKey: OperationID.derived("abandon:" + workout.workoutId)
            )
        }
        try? store.clear()
        workout = nil
        sessionRecord = nil
        pending = []
        nextRetryAt = nil
        lastError = nil
        phase = .abandoned
    }

    /// Drops the local record once a finished summary has been acknowledged and read.
    public func clearFinished() {
        guard phase == .finished else { return }
        try? store.clear()
        workout = nil
        sessionRecord = nil
        pending = []
        nextRetryAt = nil
        lastError = nil
        phase = .ready
    }

    // MARK: - Flush

    /// Sends replayable operations in order, stopping on the first failure. Acknowledged work is
    /// removed from the queue only after the server accepted it.
    /// Single-flight: concurrent callers await the pass already running, so an operation is never
    /// submitted twice. Work queued during a pass is picked up by one follow-up pass.
    @discardableResult
    public func flush(session: IOSSession) async -> WatchFlushStop {
        if let inFlight = flushTask {
            let result = await inFlight.value
            guard result == .allSent || result == .nothingToSend else { return result }
            guard hasReplayableWork() else { return result }
            return await flush(session: session)
        }
        let task = Task { @MainActor [weak self] () -> WatchFlushStop in
            guard let self else { return .nothingToSend }
            let result = await self.performFlush(session: session)
            self.flushTask = nil
            return result
        }
        flushTask = task
        return await task.value
    }

    private func hasReplayableWork() -> Bool {
        guard let capture = try? store.load() else { return false }
        return capture.operations.contains { $0.isReplayable(now: now()) }
    }

    private func performFlush(session: IOSSession) async -> WatchFlushStop {
        if case .readOnly = phase { return .nothingToSend }
        if case .ended = phase { return .nothingToSend }
        let capture: OfflineCapture
        do {
            capture = try store.load()
        } catch {
            return .storage(message(for: error))
        }
        apply(capture)
        var sentAny = false
        var offPlanRetried: Set<String> = []
        // Each pass reloads the queue so an off-plan rewrite is what gets sent, and so work added
        // while this loop is awaiting cannot be skipped or reordered.
        while true {
            let current: OfflineCapture
            do {
                current = try store.load()
            } catch {
                return .storage(message(for: error))
            }
            apply(current)
            guard let operation = current.operations.first(where: {
                $0.isReplayable(now: now())
            }) else {
                ladder.succeeded()
                nextRetryAt = nil
                return sentAny ? .allSent : .nothingToSend
            }
            do {
                _ = try store.markAttempted(operation.operationId)
                let detail = try await send(operation, session: session)
                _ = try store.remove(operation.operationId)
                if let detail {
                    _ = try store.setActiveWorkout(detail)
                    workout = detail
                    if operation.kind == .addSet {
                        rememberSetID(for: operation, in: detail)
                    }
                }
                if operation.kind == .completeWorkout {
                    markFinishAcknowledged()
                }
                sentAny = true
                ladder.succeeded()
                nextRetryAt = nil
                markOnline(session)
            } catch {
                if !offPlanRetried.contains(operation.operationId),
                   isPlanItemMismatch(error),
                   case .addSet(let body) = operation.body,
                   let original = body.planItemIndex {
                    do {
                        try applyOffPlanRewrite(
                            operationId: operation.operationId,
                            originalIndex: original
                        )
                    } catch {
                        return .storage(message(for: error))
                    }
                    offPlanRetried.insert(operation.operationId)
                    continue
                }
                let stop = handle(error, operation: operation)
                refresh()
                return stop
            }
        }
    }

    /// A foreground, network-path change or explicit retry starts a new retry burst.
    public func retryTriggered() {
        if ladder.isExhausted(at: now()) {
            _ = ladder.restartWindow(at: now())
        }
    }

    // MARK: - Private

    private func send(
        _ operation: OfflineOperation,
        session: IOSSession
    ) async throws -> WorkoutDetail? {
        switch operation.body {
        case .addSet(let body):
            return try await client.addSet(
                workoutId: operation.workoutId,
                body: body,
                session: session,
                idempotencyKey: operation.operationId,
                journaling: false
            )
        case .completeWorkout(let body):
            return try await client.completeWorkout(
                workoutId: operation.workoutId,
                body: body,
                session: session,
                idempotencyKey: operation.operationId,
                journaling: false
            )
        case .executionEvents(let events):
            _ = try await client.submitExecutionEvents(
                workoutId: operation.workoutId,
                events: events.map(enrich),
                session: session,
                idempotencyKey: operation.operationId
            )
            return nil
        case .rateForm(let body):
            _ = try await client.rateForm(
                workoutId: operation.workoutId,
                body: body,
                session: session,
                idempotencyKey: operation.operationId,
                journaling: false
            )
            return nil
        }
    }

    /// Attaches the acknowledged server set id to a completion event. A missing mapping sends
    /// no set id rather than a guess.
    private func enrich(_ event: ExecutionEvent) -> ExecutionEvent {
        guard event.eventType == .setCompleted,
              let local = event.localSetId,
              let setId = sessionRecord?.eventSetIDs?[local] else {
            return event
        }
        return ExecutionEvent(
            eventId: event.eventId,
            eventType: event.eventType,
            occurredAt: event.occurredAt,
            planItemIndex: event.planItemIndex,
            setId: setId,
            localSetId: local,
            payload: event.payload
        )
    }

    private func rememberSetID(for operation: OfflineOperation, in detail: WorkoutDetail) {
        guard case .addSet(let body) = operation.body,
              let setIndex = body.setIndex,
              var record = sessionRecord else { return }
        // The newest set with this exercise and index is the one just created. The plan-item
        // match is preferred when the server reports it; otherwise exercise + index is used.
        let candidates = (detail.sets ?? []).filter {
            ($0.setIndex ?? -1) == setIndex && $0.exerciseId == body.exerciseId
        }
        let sameItem = candidates.filter { ($0.planItemIndex ?? -1) == (body.planItemIndex ?? -2) }
        let pool = sameItem.isEmpty ? candidates : sameItem
        guard let created = pool.max(by: { ($0.setId ?? 0) < ($1.setId ?? 0) }),
              let setId = created.setId else { return }
        var mapping = record.eventSetIDs ?? [:]
        guard !mapping.values.contains(setId) else { return }
        mapping[operation.operationId] = setId
        record.eventSetIDs = mapping
        if let updated = try? store.setSession(record) {
            apply(updated)
        }
    }

    private func markFinishAcknowledged() {
        guard var record = sessionRecord, var finish = record.finish else { return }
        finish.serverAcked = true
        record.finish = finish
        if let updated = try? store.setSession(record) {
            apply(updated)
        }
        phase = .finished
    }

    private func handle(_ error: Error, operation: OfflineOperation) -> WatchFlushStop {
        guard let api = error as? APIError else {
            return transient(error)
        }
        switch api {
        case .unauthorized, .forbidden:
            return .credentialsMissing
        case .server(let status, let code, let text, _, _):
            if status == 401 || status == 403 { return .credentialsMissing }
            if status >= 500 || status == 408 || status == 429 {
                return transient(error)
            }
            if code == "not_owner" {
                phase = .readOnly
            } else if code == "workout_not_active" || code == "workout_not_found" {
                phase = .ended(.unavailable)
            }
            _ = try? store.updateState(
                operationId: operation.operationId, state: .conflict, error: text
            )
            return .conflict(code: code, message: text)
        case .http(let status, let text, _):
            if status == 401 || status == 403 { return .credentialsMissing }
            if status >= 500 { return transient(error) }
            _ = try? store.updateState(
                operationId: operation.operationId, state: .conflict, error: text
            )
            return .conflict(code: "http_\(status)", message: text)
        case .transport, .decoding:
            return transient(error)
        default:
            return transient(error)
        }
    }

    private func transient(_ error: Error) -> WatchFlushStop {
        networkPolicy.failed()
        network = networkPolicy.state
        lastError = message(for: error)
        guard let next = ladder.failed(at: now()) else {
            nextRetryAt = nil
            return .retryWindowSpent
        }
        nextRetryAt = next
        return .retry(at: next)
    }

    private func mutate(_ body: (inout OfflineCapture) throws -> Void) throws {
        let capture = try store.perform(body)
        apply(capture)
    }

    private func refresh() {
        if let capture = try? store.load() {
            apply(capture)
        }
    }

    private func apply(_ capture: OfflineCapture) {
        workout = capture.activeWorkout
        sessionRecord = capture.session
        pending = capture.operations.filter { $0.state == .pending }
    }

    // MARK: - In-capture mutations

    private func append(
        _ events: [ExecutionEvent],
        to capture: inout OfflineCapture,
        workout: WorkoutDetail
    ) throws {
        try OfflineCaptureStore.appendExecutionEvents(
            events,
            workoutId: workout.workoutId,
            activeWorkout: workout,
            to: &capture,
            now: now()
        )
    }

    private func appendOperation(
        _ operation: OfflineOperation,
        to capture: inout OfflineCapture
    ) throws {
        guard !capture.operations.contains(where: {
            $0.operationId == operation.operationId
        }) else {
            throw OfflineCaptureStoreError.invalidOperation(
                "Operation \(operation.operationId) is already queued."
            )
        }
        try OfflineCaptureStore.validateOperation(operation, against: capture)
        guard capture.operations.count < OfflineCaptureStore.maxOperations else {
            throw OfflineCaptureStoreError.full
        }
        capture.operations.append(operation)
    }

    private func dropEvents(localSetID: String, from capture: inout OfflineCapture) {
        capture.operations = capture.operations.compactMap { operation in
            guard operation.state == .pending, operation.attemptedAt == nil,
                  case .executionEvents(let events) = operation.body,
                  events.contains(where: { $0.localSetId == localSetID }) else {
                return operation
            }
            let remaining = events.filter { $0.localSetId != localSetID }
            guard !remaining.isEmpty else { return nil }
            var updated = operation
            updated.body = .executionEvents(remaining)
            return updated
        }
    }

    private func isPlanItemMismatch(_ error: Error) -> Bool {
        guard case .server(_, let code, _, _, _)? = error as? APIError else { return false }
        return code == "plan_item_mismatch"
    }

    /// Preserves the set off-plan: the accounting link is cleared, the performed data and the
    /// original index survive as provenance, and the user is told (contract §10.4).
    private func applyOffPlanRewrite(operationId: String, originalIndex: Int) throws {
        try mutate { capture in
            guard let index = capture.operations.firstIndex(where: {
                $0.operationId == operationId
            }), case .addSet(let body) = capture.operations[index].body else { return }
            capture.operations[index].body = .addSet(AddSetRequest(
                exerciseId: body.exerciseId,
                loadKg: body.loadKg,
                reps: body.reps,
                rir: body.rir,
                velocityMps: body.velocityMps,
                setIndex: body.setIndex,
                planItemIndex: nil,
                repVelocities: body.repVelocities,
                performedAt: body.performedAt
            ))
            capture.operations = capture.operations.map { operation in
                guard case .executionEvents(let events) = operation.body else { return operation }
                let updated = events.map { event -> ExecutionEvent in
                    guard event.localSetId == operationId,
                          event.eventType == .setCompleted else { return event }
                    var payload = event.payload ?? [:]
                    payload["original_plan_item_index"] = .number(Double(originalIndex))
                    return ExecutionEvent(
                        eventId: event.eventId,
                        eventType: event.eventType,
                        occurredAt: event.occurredAt,
                        planItemIndex: nil,
                        setId: event.setId,
                        localSetId: event.localSetId,
                        payload: payload
                    )
                }
                var copy = operation
                copy.body = .executionEvents(updated)
                return copy
            }
            guard var record = capture.session else { return }
            record.offPlanNoted = true
            capture.session = record
        }
    }

    private func closeRest(
        in capture: inout OfflineCapture,
        at stamp: Date,
        workout: WorkoutDetail
    ) throws {
        guard var record = capture.session, var rest = record.rest, rest.isOpen else { return }
        rest.finish(at: stamp, outcome: .completed)
        record.rest = rest
        capture.session = record
        try append([ExecutionEvent(
            eventId: UUID().uuidString.lowercased(),
            eventType: .restCompleted,
            occurredAt: ServerClock.encodedISO(stamp),
            planItemIndex: rest.planItemIndex,
            payload: nil
        )], to: &capture, workout: workout)
    }

    private func touchExercise(
        in capture: inout OfflineCapture,
        itemIndex: Int,
        at stamp: Date,
        workout: WorkoutDetail
    ) throws {
        guard var record = capture.session, record.exerciseItemIndex != itemIndex else { return }
        if let previous = record.exerciseItemIndex {
            record.exerciseItemIndex = nil
            capture.session = record
            try append([ExecutionEvent(
                eventId: UUID().uuidString.lowercased(),
                eventType: .exerciseCompleted,
                occurredAt: ServerClock.encodedISO(stamp),
                planItemIndex: previous,
                payload: nil
            )], to: &capture, workout: workout)
            record = capture.session ?? record
        }
        record.exerciseItemIndex = itemIndex
        capture.session = record
        try append([ExecutionEvent(
            eventId: UUID().uuidString.lowercased(),
            eventType: .exerciseStarted,
            occurredAt: ServerClock.encodedISO(stamp),
            planItemIndex: itemIndex,
            payload: nil
        )], to: &capture, workout: workout)
    }

    private func closeExercise(
        in capture: inout OfflineCapture,
        at stamp: Date,
        workout: WorkoutDetail
    ) throws {
        guard var record = capture.session, let itemIndex = record.exerciseItemIndex else { return }
        record.exerciseItemIndex = nil
        capture.session = record
        try append([ExecutionEvent(
            eventId: UUID().uuidString.lowercased(),
            eventType: .exerciseCompleted,
            occurredAt: ServerClock.encodedISO(stamp),
            planItemIndex: itemIndex,
            payload: nil
        )], to: &capture, workout: workout)
    }

    private func stampedNow() -> Date {
        let local = now()
        guard let clock = sessionRecord?.clock else { return local }
        return clock.stamp(action: local, localNow: local)
    }

    private func markOnline(_ session: IOSSession) {
        let host = session.baseURL.host() ?? session.baseURL.absoluteString
        networkPolicy.succeeded(host: host)
        network = networkPolicy.state
    }

    private func markOfflineIfTransport(_ error: Error) {
        if case .transport = (error as? APIError) {
            networkPolicy.failed()
            network = networkPolicy.state
        }
    }

    private func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }
}
