import Foundation

/// The payload the phone pushes over WatchConnectivity after a plan edit. It is a nudge with
/// content: the watch applies it only when it is newer and only at an idle point (contract §10.2).
public struct RemoteExecutionPayload: Codable, Sendable {
    public static let schemaVersion = 2

    public let schema: Int
    public let workoutId: String
    public let status: String
    public let planRevision: Int
    public let ownerDeviceId: String?
    public let plan: PrescriptionPlan
    /// The server-confirmed execution view at push time. The watch applies it only when the
    /// watermark is at least as new as its own (DEC-RESOLVER-23).
    public let execution: ExecutionView?

    public init(
        workoutId: String,
        status: String,
        planRevision: Int,
        ownerDeviceId: String?,
        plan: PrescriptionPlan,
        execution: ExecutionView? = nil
    ) {
        self.schema = Self.schemaVersion
        self.workoutId = workoutId
        self.status = status
        self.planRevision = planRevision
        self.ownerDeviceId = ownerDeviceId
        self.plan = plan
        self.execution = execution
    }

    public init?(workout: WorkoutDetail, revision: Int, execution: ExecutionView? = nil) {
        guard let plan = workout.plan else { return nil }
        self.init(
            workoutId: workout.workoutId,
            status: workout.status,
            planRevision: revision,
            ownerDeviceId: workout.ownerDeviceId,
            plan: plan,
            execution: execution
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
