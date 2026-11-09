import Foundation

/// One mutation that was sent but whose outcome was not acknowledged.
struct PendingMutation: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case pending
        case conflict
    }

    let operationId: String
    let deviceId: String?
    let serverURL: String
    let kind: MutationKind
    let targetId: String?
    let path: String
    let bodyData: Data
    let createdAt: Date
    var state: State

    var id: String { operationId }

    var isReplayable: Bool {
        state == .pending
            && Date().timeIntervalSince(createdAt) <= MutationJournal.replayWindow
    }
}

enum MutationKind: String, Codable, CaseIterable {
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

    var label: String {
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
        }
    }
}

enum MutationJournalError: LocalizedError, Equatable {
    case full
    case operationConflict
    case io(String)

    var errorDescription: String? {
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
final class MutationJournal {
    static let maxEntries = 16
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let replayWindow: TimeInterval = 28 * 24 * 60 * 60

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthApp", isDirectory: true)
            .appendingPathComponent("pending-mutations.json")
    }

    func all(for deviceId: String?, serverURL: String) -> [PendingMutation] {
        lock.lock()
        defer { lock.unlock() }
        guard let entries = try? load() else { return [] }
        return entries
            .filter { $0.deviceId == deviceId && $0.serverURL == serverURL }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func record(_ entry: PendingMutation) throws {
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

    func acknowledge(_ entry: PendingMutation) throws {
        try remove(entry)
    }

    func markConflict(_ entry: PendingMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try load()
        if let index = entries.firstIndex(where: { $0.operationId == entry.operationId }) {
            entries[index].state = .conflict
            try save(entries)
        }
    }

    func remove(operationId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try load()
        let before = entries.count
        entries.removeAll { $0.operationId == operationId }
        if entries.count != before {
            try save(entries)
        }
    }

    func remove(_ entry: PendingMutation) throws {
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

    func removeAll(for deviceId: String?, serverURL: String) throws {
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
