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

/// The watch's execution lifecycle (contract §11). It performs the network calls and the durable
/// local writes; HealthKit, UI and scheduling stay outside so every rule here is testable on the
/// iPhone simulator.
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

    public var pendingCount: Int { pending.count }

    public var pendingSetCount: Int {
        pending.filter { $0.kind == .addSet }.count
    }

    public var completedSetCount: Int {
        (workout?.sets?.count ?? 0) + pendingSetCount
    }

    public var planItems: [PrescriptionItem] {
        workout?.plan?.items ?? []
    }

    /// The item still short of its prescribed sets, or the last item once everything is done so
    /// an extra set can still be logged against something real.
    public var currentItem: PrescriptionItem? {
        planItems.first { item in
            setsDone(planItemIndex: item.orderIndex ?? 0) < (item.sets ?? 0)
        } ?? planItems.last
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
        workout = capture.activeWorkout
        sessionRecord = capture.session
        pending = capture.operations.filter { $0.state == .pending }
        guard capture.session != nil else {
            phase = capture.activeWorkout == nil ? .ready : .active
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
            let clock = detail.startedAt.flatMap {
                ServerClock(serverTimestamp: $0, receivedAt: receivedAt)
            }
            let record = WatchSessionRecord(
                sessionUUID: UUID().uuidString.lowercased(),
                startedAt: clock?.serverNow(from: receivedAt) ?? receivedAt,
                planRevision: 0,
                clockOffsetSeconds: clock?.offset
            )
            _ = try store.setSession(record)
            _ = try store.setActiveWorkout(detail)
            workout = detail
            sessionRecord = record
            pending = []
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

    /// Persists the set before any request and then attempts one flush pass.
    @discardableResult
    public func logSet(_ entry: SetEntry, session: IOSSession) async -> WatchFlushStop {
        guard let workoutId = workout?.workoutId, let snapshot = workout else {
            return .conflict(code: "no_workout", message: "There is no active workout.")
        }
        let localSetID: Int
        do {
            localSetID = try store.nextLocalSetId()
        } catch {
            return .storage(message(for: error))
        }
        let request = AddSetRequest(
            exerciseId: entry.exerciseId,
            loadKg: entry.loadKg,
            reps: entry.reps,
            rir: entry.rir,
            velocityMps: nil,
            setIndex: entry.setIndex,
            planItemIndex: entry.planItemIndex,
            performedAt: ServerClock.encodedISO(stampedNow())
        )
        let operation = OfflineOperation(
            operationId: UUID().uuidString.lowercased(),
            workoutId: workoutId,
            body: .addSet(request),
            createdAt: now(),
            localSetId: localSetID
        )
        do {
            _ = try store.record(operation, activeWorkout: snapshot)
            pending.append(operation)
        } catch {
            return .storage(message(for: error))
        }
        return await flush(session: session)
    }

    /// Removes the newest set that has never been attempted. Once a request may have reached the
    /// server the set is not cancellable locally (6.4 owns post-sync correction).
    @discardableResult
    public func undoLastPendingSet() -> Bool {
        guard let operation = pending.last(where: {
            $0.kind == .addSet && $0.attemptedAt == nil
        }) else { return false }
        do {
            _ = try store.cancel(operation.operationId)
        } catch {
            return false
        }
        pending.removeAll { $0.operationId == operation.operationId }
        return true
    }

    // MARK: - Rest

    public func startRest(seconds: Int) throws {
        guard seconds > 0, var record = sessionRecord else { return }
        record.rest = RestInterval(startedAt: now(), prescribedSeconds: seconds)
        _ = try store.setSession(record)
        sessionRecord = record
    }

    public func extendRest(by seconds: Int) throws {
        guard var record = sessionRecord, var rest = record.rest else { return }
        rest.extend(by: seconds)
        record.rest = rest
        _ = try store.setSession(record)
        sessionRecord = record
    }

    public func endRest(outcome: RestOutcome) throws {
        guard var record = sessionRecord, var rest = record.rest else { return }
        rest.finish(at: now(), outcome: outcome)
        record.rest = rest
        _ = try store.setSession(record)
        sessionRecord = record
    }

    // MARK: - Finish

    @discardableResult
    public func finish(sessionRpe: Double?, session: IOSSession) async -> WatchFlushStop {
        guard let workoutId = workout?.workoutId, var record = sessionRecord else {
            return .conflict(code: "no_workout", message: "There is no active workout.")
        }
        let endedAt = stampedNow()
        record.finish = FinishIntent(endedAt: endedAt, sessionRpe: sessionRpe)
        record.rest = nil
        do {
            _ = try store.setSession(record)
        } catch {
            return .storage(message(for: error))
        }
        sessionRecord = record
        phase = .finishing

        let operation = OfflineOperation(
            operationId: "watch-finish-\(record.sessionUUID)",
            workoutId: workoutId,
            body: .completeWorkout(CompleteWorkoutRequest(
                sessionRpe: sessionRpe,
                notRecorded: sessionRpe == nil,
                durationMin: nil,
                notes: nil,
                endedAt: ServerClock.encodedISO(endedAt),
                productivity: nil
            )),
            createdAt: now()
        )
        do {
            if !pending.contains(where: { $0.operationId == operation.operationId }) {
                _ = try store.record(operation, activeWorkout: workout)
                pending.append(operation)
            }
        } catch {
            return .storage(message(for: error))
        }
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
            pending = capture.operations.filter { $0.state == .pending }
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
                }
                if operation.kind == .completeWorkout {
                    markFinishAcknowledged()
                }
                ladder.succeeded()
                nextRetryAt = nil
                markOnline(session)
            } catch {
                let stop = handle(error, operation: operation)
                refreshPending()
                return stop
            }
        }
        refreshPending()
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
        case .rateForm, .executionEvents:
            throw APIError.journal("This operation is not sent by the watch in Phase 6.3.")
        }
    }

    private func markFinishAcknowledged() {
        guard var record = sessionRecord, var finish = record.finish else { return }
        finish.serverAcked = true
        record.finish = finish
        sessionRecord = record
        phase = .finished
        _ = try? store.setSession(record)
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

    private func refreshPending() {
        pending = (try? store.load().operations.filter { $0.state == .pending }) ?? pending
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
