import XCTest

@testable import StrengthApp

final class MutationJournalTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
    }

    private func entry(
        operation: String = "operation-1",
        device: String? = "device-1",
        server: String = "http://127.0.0.1:8000",
        kind: MutationKind = .addSet,
        target: String? = "workout-1",
        path: String = "api/ios/v1/workouts/workout-1/sets",
        body: Data = Data("{\"reps\":3}".utf8),
        age: TimeInterval = 0
    ) -> PendingMutation {
        PendingMutation(
            operationId: operation,
            deviceId: device,
            serverURL: server,
            kind: kind,
            targetId: target,
            path: path,
            bodyData: body,
            createdAt: Date().addingTimeInterval(-age),
            state: .pending
        )
    }

    func testJournalPersistsTheExactBodyAcrossInstances() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let body = Data([0x7b, 0x22, 0x72, 0x65, 0x70, 0x73, 0x22, 0x3a, 0x33, 0x7d])
        try MutationJournal(fileURL: url).record(entry(body: body))

        let reloaded = MutationJournal(fileURL: url)
        let entries = reloaded.all(
            for: "device-1", serverURL: "http://127.0.0.1:8000"
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].bodyData, body)
        XCTAssertEqual(entries[0].kind, .addSet)
        XCTAssertEqual(entries[0].state, .pending)

        try reloaded.acknowledge(entries[0])
        XCTAssertTrue(
            MutationJournal(fileURL: url).all(
                for: "device-1", serverURL: "http://127.0.0.1:8000"
            ).isEmpty
        )
    }

    func testJournalScopesEntriesByDeviceAndServer() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = MutationJournal(fileURL: url)
        try journal.record(entry(operation: "one", device: "device-1"))
        try journal.record(entry(operation: "two", device: "device-2"))

        XCTAssertEqual(
            journal.all(for: "device-1", serverURL: "http://127.0.0.1:8000").count,
            1
        )
        XCTAssertEqual(
            journal.all(for: "device-2", serverURL: "http://127.0.0.1:8000").count,
            1
        )
        XCTAssertEqual(
            journal.all(for: "device-1", serverURL: "http://other:8000").count,
            0
        )

        try journal.removeAll(for: "device-1", serverURL: "http://127.0.0.1:8000")
        XCTAssertTrue(
            journal.all(for: "device-1", serverURL: "http://127.0.0.1:8000").isEmpty
        )
        XCTAssertEqual(
            journal.all(for: "device-2", serverURL: "http://127.0.0.1:8000").count,
            1
        )
    }

    func testJournalRejectsAChangedBodyForTheSameOperation() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = MutationJournal(fileURL: url)
        try journal.record(entry(body: Data("{\"reps\":3}".utf8)))
        XCTAssertThrowsError(
            try journal.record(entry(body: Data("{\"reps\":4}".utf8)))
        ) { error in
            XCTAssertEqual(error as? MutationJournalError, .operationConflict)
        }
    }

    func testJournalCapsTheNumberOfPendingEntries() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = MutationJournal(fileURL: url)
        for index in 0..<MutationJournal.maxEntries {
            try journal.record(entry(operation: "operation-\(index)"))
        }
        XCTAssertThrowsError(
            try journal.record(entry(operation: "overflow"))
        ) { error in
            XCTAssertEqual(error as? MutationJournalError, .full)
        }
    }

    func testJournalMarksConflictsAndPrunesOldEntries() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = MutationJournal(fileURL: url)
        let old = entry(operation: "old", age: MutationJournal.retention + 60)
        try journal.record(old)
        let current = entry(operation: "current")
        try journal.record(current)

        let entries = journal.all(
            for: "device-1", serverURL: "http://127.0.0.1:8000"
        )
        XCTAssertEqual(entries.map(\.operationId), ["current"])

        try journal.markConflict(current)
        let conflicted = journal.all(
            for: "device-1", serverURL: "http://127.0.0.1:8000"
        )
        XCTAssertEqual(conflicted.first?.state, .conflict)
    }
}
