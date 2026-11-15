import AppIntents
import Foundation

/// One exercise in the owner's library, identified by the server's exercise id.
///
/// The entity carries an id and a display name only: it is a parameter type, not a metric.
public struct ExerciseEntity: AppEntity, Identifiable, Hashable {
    public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Exercise")
    public static var defaultQuery = ExerciseEntityQuery()

    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Exercises are the only entity indexed for Spotlight: they carry a name and an id, not training
/// data. Completed sessions stay inside the app (plan §7.6, decision 14).
extension ExerciseEntity: IndexedEntity {}

/// Resolves exercises from the server catalogue through the registered provider.
public struct ExerciseEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ExerciseEntity] {
        let provider = try await IntentServices.provider()
        let catalogue = try await provider.exerciseCatalogue()
        let wanted = Set(identifiers)
        return catalogue.filter { wanted.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [ExerciseEntity] {
        let provider = try await IntentServices.provider()
        return try await provider.exerciseCatalogue()
    }
}
