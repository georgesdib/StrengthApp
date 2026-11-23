import Foundation

/// One set as a device captured it, before the phone assigns a server index.
public struct ProvisionalSet: Equatable, Sendable {
    public let deviceId: String
    public let localSetId: String
    public let exerciseId: String
    public let setIndex: Int
    public let planItemIndex: Int?
    public let performedAt: String?

    public init(
        deviceId: String,
        localSetId: String,
        exerciseId: String,
        setIndex: Int,
        planItemIndex: Int? = nil,
        performedAt: String? = nil
    ) {
        self.deviceId = deviceId
        self.localSetId = localSetId
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.planItemIndex = planItemIndex
        self.performedAt = performedAt
    }

    public var isWarmup: Bool { setIndex >= 1000 }
}

/// The phone's merge rule (D2-D4): never reject a set. A collision is renumbered after the
/// current maximum for the same exercise, in capture order. Warm-up indexes (>= 1000) keep their
/// own band so a working set can never displace one.
public enum SetMerge {
    public static func renumber(
        _ incoming: [ProvisionalSet],
        existing: [(exerciseId: String, setIndex: Int)]
    ) -> [ProvisionalSet] {
        var used: [String: Set<Int>] = [:]
        for set in existing where set.setIndex > 0 {
            used[set.exerciseId, default: []].insert(set.setIndex)
        }
        var result: [ProvisionalSet] = []
        result.reserveCapacity(incoming.count)
        for set in incoming {
            let current = used[set.exerciseId] ?? []
            let assigned: Int
            if set.setIndex >= 1000 {
                if !current.contains(set.setIndex) {
                    assigned = set.setIndex
                } else {
                    assigned = max(current.filter { $0 >= 1000 }.max() ?? 999, 999) + 1
                }
            } else if set.setIndex > 0, !current.contains(set.setIndex) {
                assigned = set.setIndex
            } else {
                let workingMax = current.filter { $0 > 0 && $0 < 1000 }.max() ?? 0
                assigned = workingMax + 1
            }
            used[set.exerciseId, default: []].insert(assigned)
            result.append(ProvisionalSet(
                deviceId: set.deviceId,
                localSetId: set.localSetId,
                exerciseId: set.exerciseId,
                setIndex: assigned,
                planItemIndex: set.planItemIndex,
                performedAt: set.performedAt
            ))
        }
        return result
    }
}

/// The per-device translation from a local set id to the server's set id. An edit or removal
/// never guesses: a missing entry stays local until the mapping is learned from an acknowledgement.
public struct LocalSetMap: Codable, Equatable, Sendable {
    public private(set) var entries: [String: Int]

    public init(entries: [String: Int] = [:]) {
        self.entries = entries
    }

    private static func key(deviceId: String, localSetId: String) -> String {
        deviceId + "|" + localSetId
    }

    public mutating func record(deviceId: String, localSetId: String, setId: Int) {
        entries[Self.key(deviceId: deviceId, localSetId: localSetId)] = setId
    }

    public func serverSetId(deviceId: String, localSetId: String) -> Int? {
        entries[Self.key(deviceId: deviceId, localSetId: localSetId)]
    }

    /// Resolves an edit/remove target. A local set the server has already acknowledged uses the
    /// server id; an unsent local set has no server id and must be edited in the local ledger.
    public func reference(
        deviceId: String,
        localSetId: String
    ) -> LocalSetReference {
        if let setId = serverSetId(deviceId: deviceId, localSetId: localSetId) {
            return .server(setId: setId)
        }
        return .localLedger
    }
}

public enum LocalSetReference: Equatable, Sendable {
    case server(setId: Int)
    case localLedger
}
