import Foundation

/// Phase 4's durable local capture foundation.
///
/// This file deliberately contains storage and operation state only. It does not call the API,
/// render UI, or replay operations. Chunk 3/4 wire those behaviours on top of this contract.

public enum OfflineOperationKind: String, Codable, CaseIterable {
    case start
    case addSet
    case executionEvents
    case rateForm
    case completeWorkout

    public var label: String {
        switch self {
        case .start: return "Start workout"
        case .addSet: return "Add set"
        case .executionEvents: return "Execution events"
        case .rateForm: return "Form rating"
        case .completeWorkout: return "Finish workout"
        }
    }
}

public enum OfflineOperationState: String, Codable {
    case pending
    case synced
    case failed
    case conflict
    case expired
}

public enum OfflineOperationBody: Codable, Equatable {
    case start(StartWorkoutRequest)
    case addSet(AddSetRequest)
    case executionEvents([ExecutionEvent])
    case rateForm(FormRatingRequest)
    case completeWorkout(CompleteWorkoutRequest)

    public var kind: OfflineOperationKind {
        switch self {
        case .start: return .start
        case .addSet: return .addSet
        case .executionEvents: return .executionEvents
        case .rateForm: return .rateForm
        case .completeWorkout: return .completeWorkout
        }
    }
}

public enum LedgerAckState: String, Codable, Equatable {
    case pending
    case acknowledged
    case failed
    case conflict
}

/// One durable ledger entry. The v1 capture called this an operation; the fields below make the
/// ledger contract explicit while remaining optional so a version-1 file still decodes.
public struct OfflineOperation: Codable, Equatable, Identifiable {
    public let operationId: String
    public let workoutId: String
    public var body: OfflineOperationBody
    public let createdAt: Date
    public let localSetId: Int?
    public let localFormId: Int?
    public var state: OfflineOperationState
    public var lastError: String?
    public var attemptedAt: Date?
    /// Ledger provenance. Optional on a version-1 decode; the store fills them in place.
    public var deviceId: String?
    public var deviceSeq: Int?
    public var createdAtLocal: Date?
    public var clockOffsetSeconds: Double?
    public var planWatermark: Int?
    public var ackState: LedgerAckState?

    public var id: String { operationId }
    public var entryId: String { operationId }
    public var kind: OfflineOperationKind { body.kind }
    public var payload: OfflineOperationBody { body }
    public var isCancellable: Bool {
        state == .pending && attemptedAt == nil
    }

    /// A ledger entry is never aged out before acknowledgement. Only the acknowledgement (or a
    /// deliberate discard) removes it.
    public func isReplayable(now: Date = Date()) -> Bool {
        state == .pending
    }

    public init(
        operationId: String,
        workoutId: String,
        body: OfflineOperationBody,
        createdAt: Date,
        localSetId: Int? = nil,
        localFormId: Int? = nil,
        state: OfflineOperationState = .pending,
        lastError: String? = nil,
        attemptedAt: Date? = nil,
        deviceId: String? = nil,
        deviceSeq: Int? = nil,
        createdAtLocal: Date? = nil,
        clockOffsetSeconds: Double? = nil,
        planWatermark: Int? = nil,
        ackState: LedgerAckState? = nil
    ) {
        self.operationId = operationId
        self.workoutId = workoutId
        self.body = body
        self.createdAt = createdAt
        self.localSetId = localSetId
        self.localFormId = localFormId
        self.state = state
        self.lastError = lastError
        self.attemptedAt = attemptedAt
        self.deviceId = deviceId
        self.deviceSeq = deviceSeq
        self.createdAtLocal = createdAtLocal ?? createdAt
        self.clockOffsetSeconds = clockOffsetSeconds
        self.planWatermark = planWatermark
        self.ackState = ackState ?? Self.ackState(for: state)
    }

    public static func ackState(for state: OfflineOperationState) -> LedgerAckState {
        switch state {
        case .pending: return .pending
        case .synced: return .acknowledged
        case .failed, .expired: return .failed
        case .conflict: return .conflict
        }
    }
}

public struct OfflineCapture: Codable {
    /// Version 2 adds the ledger fields and the pre-start plan cache. Version 1 is decoded and
    /// migrated in place; a mid-workout app update must never make the capture unreadable.
    public static let currentVersion = 2

    public var version: Int
    public var activeWorkout: WorkoutDetail?
    public var operations: [OfflineOperation]
    public var updatedAt: Date
    /// The watch's execution record for the active session (Phase 6.3). Nil on the phone and in
    /// files written before 6.3; optional so an older capture file still decodes at version 1.
    public var session: WatchSessionRecord?
    /// The issued plan downloaded before start, with its execution identity and catalogue. Nil
    /// when no plan is cached, or in files written before offline execution.
    public var cachedPlan: CachedIssuedPlan?
    /// The catalogue the active workout was started with. It stays available after the start
    /// consumes the plan cache, so a later substitution can still be prefilled offline.
    public var activeCatalogue: LoadCatalogue?
    /// Optimistic execution changes authored on this phone. They are applied to the local view
    /// before the server answers; a rejected change stays here marked unresolved rather than
    /// silently reverting.
    public var localExecutionChanges: [ExecutionChange]?

    public init(
        version: Int = OfflineCapture.currentVersion,
        activeWorkout: WorkoutDetail? = nil,
        operations: [OfflineOperation] = [],
        updatedAt: Date = Date(),
        session: WatchSessionRecord? = nil,
        cachedPlan: CachedIssuedPlan? = nil,
        activeCatalogue: LoadCatalogue? = nil,
        localExecutionChanges: [ExecutionChange]? = nil
    ) {
        self.version = version
        self.activeWorkout = activeWorkout
        self.operations = operations
        self.updatedAt = updatedAt
        self.session = session
        self.cachedPlan = cachedPlan
        self.activeCatalogue = activeCatalogue
        self.localExecutionChanges = localExecutionChanges
    }
}

public enum OfflineCaptureStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case full
    case invalidOperation(String)
    case operationNotFound(String)
    /// The store exists but the phone is locked and its protection key is unavailable. This is
    /// temporary and never a reason to discard data: the store resumes after the next unlock.
    case deviceLocked
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "The offline capture file uses unsupported version \(version)."
        case .full:
            return "The offline capture queue is full. Resolve pending work before adding more."
        case .invalidOperation(let message):
            return message
        case .operationNotFound(let id):
            return "Offline operation \(id) was not found."
        case .deviceLocked:
            return "Offline capture is paused while this device is locked. It resumes after the next unlock."
        case .io(let message):
            return "Offline capture storage failed: \(message)"
        }
    }
}

/// One protected, backup-excluded file holding the active-workout snapshot and ordered operations.
public final class OfflineCaptureStore {
    public static let maxOperations = 128
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    public static let replayWindow: TimeInterval = 28 * 24 * 60 * 60

    private let fileURL: URL
    private let now: () -> Date
    private let lock = NSLock()

    public init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.now = now
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthApp", isDirectory: true)
            .appendingPathComponent("offline-capture.json")
    }

    public func load() throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        let capture = try loadUnlocked()
        let normalized = expireUnsafeOperations(capture)
        if normalized.operations.count == capture.operations.count,
           zip(normalized.operations, capture.operations).allSatisfy({ $0.state == $1.state }) {
            return normalized
        }
        try saveUnlocked(normalized)
        return normalized
    }

    public func save(_ capture: OfflineCapture) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(capture)
    }

    public func setActiveWorkout(_ workout: WorkoutDetail?) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        if let current = capture.activeWorkout?.workoutId,
           let next = workout?.workoutId,
           current != next,
           !capture.operations.isEmpty {
            throw OfflineCaptureStoreError.invalidOperation(
                "Resolve queued work before switching to a different active workout."
            )
        }
        capture.activeWorkout = workout
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// One atomic write: apply several related changes to the capture and persist it once, so a
    /// termination cannot leave a half-updated session or outbox.
    public func perform(
        _ body: (inout OfflineCapture) throws -> Void
    ) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        try body(&capture)
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// Appends events inside a caller's capture mutation, merging only into the newest operation
    /// so a completion can never overtake the set it describes.
    public static func appendExecutionEvents(
        _ events: [ExecutionEvent],
        workoutId: String,
        activeWorkout: WorkoutDetail?,
        to capture: inout OfflineCapture,
        now: Date
    ) throws {
        guard !events.isEmpty else { return }
        if let activeWorkout {
            if let current = capture.activeWorkout?.workoutId,
               current != activeWorkout.workoutId,
               !capture.operations.isEmpty {
                throw OfflineCaptureStoreError.invalidOperation(
                    "Resolve queued work before switching to a different active workout."
                )
            }
            capture.activeWorkout = activeWorkout
        }
        if let index = capture.operations.indices.last,
           capture.operations[index].workoutId == workoutId,
           capture.operations[index].state == .pending,
           capture.operations[index].attemptedAt == nil,
           case .executionEvents(var queued) = capture.operations[index].body,
           queued.count + events.count <= 100 {
            queued.append(contentsOf: events)
            capture.operations[index].body = .executionEvents(queued)
        } else {
            guard capture.operations.count < maxOperations else {
                throw OfflineCaptureStoreError.full
            }
            let sequence = (capture.operations.compactMap(\.deviceSeq).max() ?? -1) + 1
            capture.operations.append(OfflineOperation(
                operationId: UUID().uuidString.lowercased(),
                workoutId: workoutId,
                body: .executionEvents(events),
                createdAt: now,
                deviceId: capture.session?.deviceId,
                deviceSeq: sequence,
                clockOffsetSeconds: capture.session?.clockOffsetSeconds,
                planWatermark: capture.session?.execution?.watermark
            ))
        }
    }

    /// Drops queued telemetry that belongs to a set whose capture was undone before it was ever
    /// sent. Attempted batches are left alone so the server and the queue never disagree.
    public func removeExecutionEvents(localSetID: String) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        var kept: [OfflineOperation] = []
        var changed = false
        for operation in capture.operations {
            guard operation.state == .pending, operation.attemptedAt == nil,
                  case .executionEvents(let events) = operation.body,
                  events.contains(where: { $0.localSetId == localSetID }) else {
                kept.append(operation)
                continue
            }
            let remaining = events.filter { $0.localSetId != localSetID }
            changed = true
            guard !remaining.isEmpty else { continue }
            var updated = operation
            updated.body = .executionEvents(remaining)
            kept.append(updated)
        }
        guard changed else { return capture }
        capture.operations = kept
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// Persists the watch session record without touching the operation queue or the active
    /// workout snapshot. Passing nil clears it, for example after a finished summary is
    /// acknowledged.
    public func setSession(_ session: WatchSessionRecord?) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        capture.session = session
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// Stores the issued plan before it is started, so a relaunch (or an offline watch) still has
    /// the plan, its execution id and the catalogue it shipped.
    public func setCachedPlan(_ plan: CachedIssuedPlan?) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        capture.cachedPlan = plan
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// Keeps the catalogue beside the active workout after the start consumed the plan cache.
    public func setActiveCatalogue(_ catalogue: LoadCatalogue?) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        capture.activeCatalogue = catalogue
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// Persists optimistic execution changes independently of the operation queue.
    public func setLocalExecutionChanges(
        _ changes: [ExecutionChange]
    ) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        capture.localExecutionChanges = changes.isEmpty ? nil : changes
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    public func record(_ operation: OfflineOperation) throws -> OfflineCapture {
        try record(operation, activeWorkout: nil)
    }

    /// Atomically append an operation and the optimistic workout it belongs to.
    public func record(_ operation: OfflineOperation, activeWorkout: WorkoutDetail?) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        if let activeWorkout {
            if let current = capture.activeWorkout?.workoutId,
               current != activeWorkout.workoutId,
               !capture.operations.isEmpty {
                throw OfflineCaptureStoreError.invalidOperation(
                    "Resolve queued work before switching to a different active workout."
                )
            }
            capture.activeWorkout = activeWorkout
        }
        guard !capture.operations.contains(where: {
            $0.operationId == operation.operationId
        }) else {
            throw OfflineCaptureStoreError.invalidOperation(
                "Operation \(operation.operationId) is already queued."
            )
        }
        try Self.validateOperation(operation, against: capture)
        guard capture.operations.count < Self.maxOperations else {
            throw OfflineCaptureStoreError.full
        }
        var entry = operation
        if entry.deviceSeq == nil {
            entry.deviceSeq = (capture.operations.compactMap(\.deviceSeq).max() ?? -1) + 1
        }
        if entry.createdAtLocal == nil {
            entry.createdAtLocal = entry.createdAt
        }
        if entry.ackState == nil {
            entry.ackState = .pending
        }
        if entry.deviceId == nil { entry.deviceId = capture.session?.deviceId }
        if entry.clockOffsetSeconds == nil {
            entry.clockOffsetSeconds = capture.session?.clockOffsetSeconds
        }
        if entry.planWatermark == nil {
            entry.planWatermark = capture.session?.execution?.watermark
        }
        capture.operations.append(entry)
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// Appends execution events to the newest unsent batch for this workout, or creates a
    /// new durable batch. Individual events keep their original occurrence timestamps and IDs.
    public func appendExecutionEvents(
        workoutId: String,
        events: [ExecutionEvent],
        activeWorkout: WorkoutDetail?
    ) throws -> OfflineCapture {
        guard !events.isEmpty else { return try load() }
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        if let activeWorkout {
            if let current = capture.activeWorkout?.workoutId,
               current != activeWorkout.workoutId,
               !capture.operations.isEmpty {
                throw OfflineCaptureStoreError.invalidOperation(
                    "Resolve queued work before switching to a different active workout."
                )
            }
            capture.activeWorkout = activeWorkout
        }
        // Merge only into the newest operation: batching into an older batch would move these
        // events ahead of a set queued after it, breaking original order and set-id enrichment.
        if let index = capture.operations.indices.last,
           capture.operations[index].workoutId == workoutId,
           capture.operations[index].state == .pending,
           capture.operations[index].attemptedAt == nil,
           case .executionEvents(var queued) = capture.operations[index].body,
           queued.count + events.count <= 100 {
            queued.append(contentsOf: events)
            capture.operations[index].body = .executionEvents(queued)
        } else {
            guard capture.operations.count < Self.maxOperations else {
                throw OfflineCaptureStoreError.full
            }
            let sequence = (capture.operations.compactMap(\.deviceSeq).max() ?? -1) + 1
            capture.operations.append(OfflineOperation(
                operationId: UUID().uuidString.lowercased(),
                workoutId: workoutId,
                body: .executionEvents(events),
                createdAt: now(),
                deviceId: capture.session?.deviceId,
                deviceSeq: sequence,
                clockOffsetSeconds: capture.session?.clockOffsetSeconds,
                planWatermark: capture.session?.execution?.watermark
            ))
        }
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    /// Rewrites one queued set's index after the server reports a collision. The rest of the
    /// request is untouched, so its idempotency identity keeps the same payload apart from the
    /// index that must change.
    public func replaceAddSetIndex(
        operationId: String,
        setIndex: Int
    ) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        guard let index = capture.operations.firstIndex(where: {
            $0.operationId == operationId
        }) else {
            throw OfflineCaptureStoreError.operationNotFound(operationId)
        }
        guard case .addSet(var body) = capture.operations[index].body else {
            throw OfflineCaptureStoreError.invalidOperation(
                "Only an add-set operation has a set index."
            )
        }
        body = body.withSetIndex(setIndex)
        capture.operations[index].body = .addSet(body)
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    public func updateState(
        operationId: String,
        state: OfflineOperationState,
        error: String? = nil,
        attemptedAt: Date? = nil
    ) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        guard let index = capture.operations.firstIndex(where: {
            $0.operationId == operationId
        }) else {
            throw OfflineCaptureStoreError.operationNotFound(operationId)
        }
        capture.operations[index].state = state
        capture.operations[index].ackState = OfflineOperation.ackState(for: state)
        capture.operations[index].lastError = error
        if let attemptedAt {
            capture.operations[index].attemptedAt = attemptedAt
        }
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    public func markAttempted(_ operationId: String) throws -> OfflineCapture {
        try updateState(
            operationId: operationId,
            state: .pending,
            attemptedAt: now()
        )
    }

    /// Removes an operation only while it has never been sent. Once attempted, server
    /// acknowledgement/conflict resolution owns it.
    public func cancel(_ operationId: String) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        guard let index = capture.operations.firstIndex(where: {
            $0.operationId == operationId
        }) else {
            throw OfflineCaptureStoreError.operationNotFound(operationId)
        }
        guard capture.operations[index].isCancellable else {
            throw OfflineCaptureStoreError.invalidOperation(
                "An operation that has already been sent cannot be cancelled locally."
            )
        }
        capture.operations.remove(at: index)
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    public func remove(_ operationId: String) throws -> OfflineCapture {
        lock.lock()
        defer { lock.unlock() }
        var capture = try loadUnlocked()
        guard capture.operations.contains(where: {
            $0.operationId == operationId
        }) else {
            throw OfflineCaptureStoreError.operationNotFound(operationId)
        }
        capture.operations.removeAll { $0.operationId == operationId }
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    public func replayable(now: Date? = nil) throws -> [OfflineOperation] {
        let current = now ?? self.now()
        return try load().operations.filter { $0.isReplayable(now: current) }
    }

    public func nextLocalSetId() throws -> Int {
        let capture = try load()
        let used = Set(capture.operations.compactMap(\.localSetId))
        var candidate = -1
        while used.contains(candidate) {
            candidate -= 1
        }
        return candidate
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(OfflineCapture(updatedAt: now()))
    }

    /// Ledger entries are not aged out before acknowledgement. Kept as a no-op so callers that
    /// still read a v1 file cannot turn unsent work into an expired entry on upgrade.
    private func expireUnsafeOperations(_ capture: OfflineCapture) -> OfflineCapture {
        capture
    }

    /// Fills the ledger-only fields a version-1 file did not persist. No set is dropped and the
    /// operation order is preserved.
    private func migrateLedgerFields(_ capture: inout OfflineCapture) {
        var nextSequence = (capture.operations.compactMap(\.deviceSeq).max() ?? -1) + 1
        for index in capture.operations.indices {
            if capture.operations[index].createdAtLocal == nil {
                capture.operations[index].createdAtLocal = capture.operations[index].createdAt
            }
            if capture.operations[index].deviceSeq == nil {
                capture.operations[index].deviceSeq = nextSequence
                nextSequence += 1
            }
            if capture.operations[index].ackState == nil {
                capture.operations[index].ackState = OfflineOperation.ackState(
                    for: capture.operations[index].state
                )
            }
        }
        capture.version = OfflineCapture.currentVersion
    }

    public static func validateOperation(
        _ operation: OfflineOperation,
        against capture: OfflineCapture
    ) throws {
        if let localSetId = operation.localSetId {
            guard operation.kind == .addSet, localSetId < 0 else {
                throw OfflineCaptureStoreError.invalidOperation(
                    "Only an unsynced add-set operation may carry a negative local set id."
                )
            }
            guard !capture.operations.contains(where: {
                $0.localSetId == localSetId
            }) else {
                throw OfflineCaptureStoreError.invalidOperation(
                    "Local set id \(localSetId) is already in use."
                )
            }
        } else if operation.kind == .addSet {
            throw OfflineCaptureStoreError.invalidOperation(
                "An add-set operation requires a local set id."
            )
        }
        guard operation.workoutId == capture.activeWorkout?.workoutId
                || capture.activeWorkout == nil else {
            throw OfflineCaptureStoreError.invalidOperation(
                "The operation targets a different active workout."
            )
        }
    }

    private func loadUnlocked() throws -> OfflineCapture {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return OfflineCapture(updatedAt: now())
        }
        do {
            let data = try readUnlockedData()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var capture = try decoder.decode(OfflineCapture.self, from: data)
            guard capture.version >= 1,
                  capture.version <= OfflineCapture.currentVersion else {
                throw OfflineCaptureStoreError.unsupportedVersion(capture.version)
            }
            if capture.version < OfflineCapture.currentVersion {
                // Decode and migrate in place. The write is atomic, so a termination during the
                // upgrade leaves either the original v1 file or the migrated v2 file.
                migrateLedgerFields(&capture)
                try saveUnlocked(capture)
            }
            // A file written before the protection class changed is readable now, so move it off
            // the complete class before the next background wake needs it.
            DurableFileProtection.adopt(at: fileURL)
            return capture
        } catch let error as OfflineCaptureStoreError {
            throw error
        } catch {
            throw OfflineCaptureStoreError.io(error.localizedDescription)
        }
    }

    /// Reads the capture, tolerating only one specific failure: a file left with complete file
    /// protection by an older build is refused while the device is locked. Relaxing the class and
    /// retrying costs nothing when it is unlocked, and reports a resumable lock otherwise.
    /// The file is never replaced on a read failure, so queued work cannot be lost.
    private func readUnlockedData() throws -> Data {
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            guard DurableFileProtection.isAccessDenied(error) else { throw error }
            DurableFileProtection.adopt(at: fileURL)
            do {
                return try Data(contentsOf: fileURL)
            } catch {
                guard DurableFileProtection.isAccessDenied(error) else { throw error }
                throw OfflineCaptureStoreError.deviceLocked
            }
        }
    }

    private func saveUnlocked(_ capture: OfflineCapture) throws {
        var clean = capture
        clean.version = OfflineCapture.currentVersion
        clean.updatedAt = now()
        guard clean.operations.count <= Self.maxOperations else {
            throw OfflineCaptureStoreError.full
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(clean)
            try data.write(to: fileURL, options: DurableFileProtection.writingOptions)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try? url.setResourceValues(values)
        } catch let error as OfflineCaptureStoreError {
            throw error
        } catch {
            if DurableFileProtection.isAccessDenied(error) {
                throw OfflineCaptureStoreError.deviceLocked
            }
            throw OfflineCaptureStoreError.io(error.localizedDescription)
        }
    }
}
