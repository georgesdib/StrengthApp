import Foundation

/// Phase 4's durable local capture foundation.
///
/// This file deliberately contains storage and operation state only. It does not call the API,
/// render UI, or replay operations. Chunk 3/4 wire those behaviours on top of this contract.

enum OfflineOperationKind: String, Codable, CaseIterable {
    case addSet
    case rateForm
    case completeWorkout

    var label: String {
        switch self {
        case .addSet: return "Add set"
        case .rateForm: return "Form rating"
        case .completeWorkout: return "Finish workout"
        }
    }
}

enum OfflineOperationState: String, Codable {
    case pending
    case synced
    case failed
    case conflict
    case expired
}

enum OfflineOperationBody: Codable, Equatable {
    case addSet(AddSetRequest)
    case rateForm(FormRatingRequest)
    case completeWorkout(CompleteWorkoutRequest)

    var kind: OfflineOperationKind {
        switch self {
        case .addSet: return .addSet
        case .rateForm: return .rateForm
        case .completeWorkout: return .completeWorkout
        }
    }
}

struct OfflineOperation: Codable, Equatable, Identifiable {
    let operationId: String
    let workoutId: String
    let body: OfflineOperationBody
    let createdAt: Date
    let localSetId: Int?
    let localFormId: Int?
    var state: OfflineOperationState
    var lastError: String?
    var attemptedAt: Date?

    var id: String { operationId }
    var kind: OfflineOperationKind { body.kind }
    var isCancellable: Bool {
        state == .pending && attemptedAt == nil
    }

    func isReplayable(now: Date = Date()) -> Bool {
        state == .pending
            && now.timeIntervalSince(createdAt) <= OfflineCaptureStore.replayWindow
    }

    init(
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

struct OfflineCapture: Codable {
    static let currentVersion = 1

    var version: Int
    var activeWorkout: WorkoutDetail?
    var operations: [OfflineOperation]
    var updatedAt: Date

    init(
        version: Int = OfflineCapture.currentVersion,
        activeWorkout: WorkoutDetail? = nil,
        operations: [OfflineOperation] = [],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.activeWorkout = activeWorkout
        self.operations = operations
        self.updatedAt = updatedAt
    }
}

enum OfflineCaptureStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case full
    case invalidOperation(String)
    case operationNotFound(String)
    case io(String)

    var errorDescription: String? {
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
final class OfflineCaptureStore {
    static let maxOperations = 128
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let replayWindow: TimeInterval = 28 * 24 * 60 * 60

    private let fileURL: URL
    private let now: () -> Date
    private let lock = NSLock()

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.now = now
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthApp", isDirectory: true)
            .appendingPathComponent("offline-capture.json")
    }

    func load() throws -> OfflineCapture {
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

    func save(_ capture: OfflineCapture) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(capture)
    }

    func setActiveWorkout(_ workout: WorkoutDetail?) throws -> OfflineCapture {
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

    func record(_ operation: OfflineOperation) throws -> OfflineCapture {
        try record(operation, activeWorkout: nil)
    }

    /// Atomically append an operation and the optimistic workout it belongs to.
    func record(_ operation: OfflineOperation, activeWorkout: WorkoutDetail?) throws -> OfflineCapture {
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
        try validate(operation, against: capture)
        guard capture.operations.count < Self.maxOperations else {
            throw OfflineCaptureStoreError.full
        }
        capture.operations.append(operation)
        try saveUnlocked(capture)
        return try loadUnlocked()
    }

    func updateState(
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

    func markAttempted(_ operationId: String) throws -> OfflineCapture {
        try updateState(
            operationId: operationId,
            state: .pending,
            attemptedAt: now()
        )
    }

    /// Removes an operation only while it has never been sent. Once attempted, server
    /// acknowledgement/conflict resolution owns it.
    func cancel(_ operationId: String) throws -> OfflineCapture {
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

    func remove(_ operationId: String) throws -> OfflineCapture {
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

    func replayable(now: Date? = nil) throws -> [OfflineOperation] {
        let current = now ?? self.now()
        return try load().operations.filter { $0.isReplayable(now: current) }
    }

    func nextLocalSetId() throws -> Int {
        let capture = try load()
        let used = Set(capture.operations.compactMap(\.localSetId))
        var candidate = -1
        while used.contains(candidate) {
            candidate -= 1
        }
        return candidate
    }

    func clear() throws {
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

    private func validate(_ operation: OfflineOperation, against capture: OfflineCapture) throws {
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
