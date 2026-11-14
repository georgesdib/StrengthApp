import Foundation

/// One mutation that was sent but whose outcome was not acknowledged.
public struct PendingMutation: Codable, Equatable, Identifiable {
    public enum State: String, Codable {
        case pending
        case conflict
    }

    public let operationId: String
    public let deviceId: String?
    public let serverURL: String
    public let kind: MutationKind
    public let targetId: String?
    public let path: String
    public let bodyData: Data
    public let createdAt: Date
    public var state: State

    public init(
        operationId: String,
        deviceId: String?,
        serverURL: String,
        kind: MutationKind,
        targetId: String?,
        path: String,
        bodyData: Data,
        createdAt: Date,
        state: State = .pending
    ) {
        self.operationId = operationId
        self.deviceId = deviceId
        self.serverURL = serverURL
        self.kind = kind
        self.targetId = targetId
        self.path = path
        self.bodyData = bodyData
        self.createdAt = createdAt
        self.state = state
    }

    public var id: String { operationId }

    public var isReplayable: Bool {
        state == .pending
            && Date().timeIntervalSince(createdAt) <= MutationJournal.replayWindow
    }
}

public enum MutationKind: String, Codable, CaseIterable {
    case readiness
    case healthkitReadiness
    case prescription
    case startWorkout
    case addSet
    case removeSet
    case executionEvents
    case rateForm
    case planEdit
    case completeWorkout
    case abandonWorkout
    case takeover

    public var label: String {
        switch self {
        case .readiness: return "Readiness"
        case .healthkitReadiness: return "HealthKit readiness"
        case .prescription: return "Prescription"
        case .startWorkout: return "Start workout"
        case .addSet: return "Add set"
        case .removeSet: return "Remove set"
        case .executionEvents: return "Execution events"
        case .rateForm: return "Form rating"
        case .planEdit: return "Plan edit"
        case .completeWorkout: return "Complete workout"
        case .abandonWorkout: return "Abandon workout"
        case .takeover: return "Take over logging"
        }
    }
}

public enum MutationJournalError: LocalizedError, Equatable {
    case full
    case operationConflict
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .full:
            return "Too many unconfirmed operations are already waiting. Resolve them before trying again."
        case .operationConflict:
            return "That operation ID was already used with a different request."
        case .io(let message):
            return "Could not save the pending operation: \(message)"
        }
    }
}

/// Durable journal for mutations that were actually attempted.
///
/// This is deliberately not an offline queue: entries are written immediately before the HTTP
/// request, capped, aged out, and only replayed with the original UUID and exact encoded body.
/// Files use iOS data protection and are excluded from backup.
public final class MutationJournal {
    public static let maxEntries = 16
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    public static let replayWindow: TimeInterval = 28 * 24 * 60 * 60

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthApp", isDirectory: true)
            .appendingPathComponent("pending-mutations.json")
    }

    public func all(for deviceId: String?, serverURL: String) -> [PendingMutation] {
        lock.lock()
        defer { lock.unlock() }
        guard let entries = try? load() else { return [] }
        return entries
            .filter { $0.deviceId == deviceId && $0.serverURL == serverURL }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func record(_ entry: PendingMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try load()
        entries = prune(entries)
        if let existing = entries.first(where: { $0.operationId == entry.operationId }) {
            if existing.deviceId == entry.deviceId,
               existing.serverURL == entry.serverURL,
               existing.kind == entry.kind,
               existing.path == entry.path,
               existing.bodyData == entry.bodyData {
                return
            }
            throw MutationJournalError.operationConflict
        }
        guard entries.count < Self.maxEntries else {
            throw MutationJournalError.full
        }
        entries.append(entry)
        try save(entries)
    }

    public func acknowledge(_ entry: PendingMutation) throws {
        try remove(entry)
    }

    public func markConflict(_ entry: PendingMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try load()
        if let index = entries.firstIndex(where: { $0.operationId == entry.operationId }) {
            entries[index].state = .conflict
            try save(entries)
        }
    }

    public func remove(operationId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try load()
        let before = entries.count
        entries.removeAll { $0.operationId == operationId }
        if entries.count != before {
            try save(entries)
        }
    }

    public func remove(_ entry: PendingMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try load()
        let before = entries.count
        entries.removeAll {
            $0.operationId == entry.operationId
                && $0.deviceId == entry.deviceId
                && $0.serverURL == entry.serverURL
        }
        if entries.count != before {
            try save(entries)
        }
    }

    public func removeAll(for deviceId: String?, serverURL: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try load()
        let before = entries.count
        entries.removeAll {
            $0.deviceId == deviceId && $0.serverURL == serverURL
        }
        if entries.count != before {
            try save(entries)
        }
    }

    private func load() throws -> [PendingMutation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([PendingMutation].self, from: data)
        } catch {
            throw MutationJournalError.io(error.localizedDescription)
        }
    }

    private func save(_ entries: [PendingMutation]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try? url.setResourceValues(values)
        } catch {
            throw MutationJournalError.io(error.localizedDescription)
        }
    }

    private func prune(_ entries: [PendingMutation]) -> [PendingMutation] {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return entries.filter { $0.createdAt >= cutoff }
    }
}
