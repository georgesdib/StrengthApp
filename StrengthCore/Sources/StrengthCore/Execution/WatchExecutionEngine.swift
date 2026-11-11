import Foundation

public enum WatchExecutionPhase: Equatable, Sendable {
    case ready
    case starting
    case active
    case finishing
    case finished
    case abandoned
}

/// The outcome of one flush pass. The caller decides when to try again; the engine never
/// schedules its own timer.
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

        public init(
            exerciseId: String,
            planItemIndex: Int?,
            setIndex: Int,
            loadKg: Double?,
            reps: Int,
            rir: Int?
        ) {
            self.exerciseId = exerciseId
            self.planItemIndex = planItemIndex
            self.setIndex = setIndex
            self.loadKg = loadKg
            self.reps = reps
            self.rir = rir
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

    private let client: IOSAPIClient
    private let store: OfflineCaptureStore
    private var ladder = RetryLadder()
    private var networkPolicy = HomeNetworkPolicy()
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

    public var activeSet: ActiveSet? {
        sessionRecord?.activeSet
    }

    public var exerciseItemIndex: Int? {
        sessionRecord?.exerciseItemIndex
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

    public var canUndoLastSet: Bool {
        pending.contains { $0.kind == .addSet && $0.attemptedAt == nil }
    }

    public var canDiscard: Bool {
        workout != nil && (phase == .active || phase == .finishing)
    }

    // MARK: - Restore

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
                idempotencyKey: "watch-start-\(issuedPlanID)"
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
            phase = .active
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
        guard let item = selectedItem, let workout else { return }
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
            guard var record = capture.session else { return }
            record.selectedItemIndex = nil
            capture.session = record
        }
    }

    /// Ends an open rest at this instant, because starting or logging the next set is what
    /// really ends recovery (contract §13; owner decision 2026-11-11).
    public func endRest() throws {
        guard let workout else { return }
        let stamp = stampedNow()
        try mutate { capture in
            try self.closeRest(in: &capture, at: stamp, workout: workout)
        }
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
            velocityMps: nil,
            setIndex: entry.setIndex,
            planItemIndex: entry.planItemIndex,
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
        return CaptureResult(persisted: true, stop: await flush(session: session))
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
        guard let workoutId = workout?.workoutId, let workout, sessionRecord != nil else {
            return .conflict(code: "no_workout", message: "There is no active workout.")
        }
        let endedAt = stampedNow()
        let operation = OfflineOperation(
            operationId: "watch-finish-\(sessionRecord?.sessionUUID ?? workoutId)",
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
                idempotencyKey: "watch-abandon-\(workout.workoutId)"
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
    @discardableResult
    public func flush(session: IOSSession) async -> WatchFlushStop {
        let capture: OfflineCapture
        do {
            capture = try store.load()
        } catch {
            return .storage(message(for: error))
        }
        let operations = capture.operations.filter { $0.isReplayable(now: now()) }
        guard !operations.isEmpty else {
            apply(capture)
            ladder.succeeded()
            nextRetryAt = nil
            return .nothingToSend
        }
        for operation in operations {
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
                ladder.succeeded()
                nextRetryAt = nil
                markOnline(session)
            } catch {
                let stop = handle(error, operation: operation)
                refresh()
                return stop
            }
        }
        refresh()
        return .allSent
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
        case .rateForm:
            throw APIError.journal("Form ratings are not captured on the watch in Phase 6.3.")
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
