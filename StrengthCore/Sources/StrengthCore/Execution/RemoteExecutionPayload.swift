import Foundation

/// The payload the phone pushes over WatchConnectivity after a plan edit. It is a nudge with
/// content: the watch applies it only when it is newer and only at an idle point (contract §10.2).
public struct RemoteExecutionPayload: Codable, Sendable {
    public static let schemaVersion = 1

    public let schema: Int
    public let workoutId: String
    public let status: String
    public let planRevision: Int
    public let ownerDeviceId: String?
    public let plan: PrescriptionPlan

    public init(
        workoutId: String,
        status: String,
        planRevision: Int,
        ownerDeviceId: String?,
        plan: PrescriptionPlan
    ) {
        self.schema = Self.schemaVersion
        self.workoutId = workoutId
        self.status = status
        self.planRevision = planRevision
        self.ownerDeviceId = ownerDeviceId
        self.plan = plan
    }

    public init?(workout: WorkoutDetail, revision: Int) {
        guard let plan = workout.plan else { return nil }
        self.init(
            workoutId: workout.workoutId,
            status: workout.status,
            planRevision: revision,
            ownerDeviceId: workout.ownerDeviceId,
            plan: plan
        )
    }

    public func encodedString() -> String? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ string: String) -> RemoteExecutionPayload? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = string.data(using: .utf8),
              let payload = try? decoder.decode(RemoteExecutionPayload.self, from: data),
              payload.schema == schemaVersion else {
            return nil
        }
        return payload
    }
}

/// Which device is allowed to log. A watch-owned session puts the phone in mirror mode.
public enum MirrorPolicy {
    public static func isMirror(workout: WorkoutDetail?, phoneDeviceID: String?) -> Bool {
        guard let owner = workout?.ownerDeviceId, !owner.isEmpty else {
            return false    // legacy rows keep the permissive behaviour (contract §9)
        }
        guard let phoneDeviceID, !phoneDeviceID.isEmpty else { return true }
        return owner != phoneDeviceID
    }
}
