import Foundation

/// Phase 4's durable local capture foundation.
///
/// This file deliberately contains storage and operation state only. It does not call the API,
/// render UI, or replay operations. Chunk 3/4 wire those behaviours on top of this contract.

public enum OfflineOperationKind: String, Codable, CaseIterable {
    case addSet
    case executionEvents
    case rateForm
    case completeWorkout

    public var label: String {
        switch self {
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
    case addSet(AddSetRequest)
    case executionEvents([ExecutionEvent])
    case rateForm(FormRatingRequest)
    case completeWorkout(CompleteWorkoutRequest)

    public var kind: OfflineOperationKind {
        switch self {
        case .addSet: return .addSet
        case .executionEvents: return .executionEvents
        case .rateForm: return .rateForm
        case .completeWorkout: return .completeWorkout
        }
    }
}

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

    public var id: String { operationId }
    public var kind: OfflineOperationKind { body.kind }
    public var isCancellable: Bool {
        state == .pending && attemptedAt == nil
    }

    public func isReplayable(now: Date = Date()) -> Bool {
        state == .pending
            && now.timeIntervalSince(createdAt) <= OfflineCaptureStore.replayWindow
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
        attemptedAt: Date? = nil
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
    }
}

public struct OfflineCapture: Codable {
    public static let currentVersion = 1

    public var version: Int
    public var activeWorkout: WorkoutDetail?
    public var operations: [OfflineOperation]
    public var updatedAt: Date
    /// The watch's execution record for the active session (Phase 6.3). Nil on the phone and in
    /// files written before 6.3; optional so an older capture file still decodes at version 1.
    public var session: WatchSessionRecord?

    public init(
        version: Int = OfflineCapture.currentVersion,
        activeWorkout: WorkoutDetail? = nil,
        operations: [OfflineOperation] = [],
        updatedAt: Date = Date(),
        session: WatchSessionRecord? = nil
    ) {
        self.version = version
        self.activeWorkout = activeWorkout
        self.operations = operations
        self.updatedAt = updatedAt
        self.session = session
    }
}

public enum OfflineCaptureStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case full
    case invalidOperation(String)
    case operationNotFound(String)
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
            capture.operations.append(OfflineOperation(
                operationId: UUID().uuidString.lowercased(),
                workoutId: workoutId,
                body: .executionEvents(events),
                createdAt: now
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
        capture.operations.append(operation)
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
            capture.operations.append(OfflineOperation(
                operationId: UUID().uuidString.lowercased(),
                workoutId: workoutId,
                body: .executionEvents(events),
                createdAt: now()
            ))
        }
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

    private func expireUnsafeOperations(_ capture: OfflineCapture) -> OfflineCapture {
        let cutoff = now().addingTimeInterval(-Self.replayWindow)
        var result = capture
        for index in result.operations.indices {
            guard result.operations[index].state == .pending,
                  result.operations[index].createdAt < cutoff else { continue }
            result.operations[index].state = .expired
            result.operations[index].lastError =
                "Older than the 28-day replay window; reconcile or discard it."
        }
        return result
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
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let capture = try decoder.decode(OfflineCapture.self, from: data)
            guard capture.version == OfflineCapture.currentVersion else {
                throw OfflineCaptureStoreError.unsupportedVersion(capture.version)
            }
            return capture
        } catch let error as OfflineCaptureStoreError {
            throw error
        } catch {
            throw OfflineCaptureStoreError.io(error.localizedDescription)
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
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try? url.setResourceValues(values)
        } catch let error as OfflineCaptureStoreError {
            throw error
        } catch {
            throw OfflineCaptureStoreError.io(error.localizedDescription)
        }
    }
}
