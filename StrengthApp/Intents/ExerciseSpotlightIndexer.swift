import AppIntents
import CoreSpotlight
import Foundation
import os
import StrengthCore
import StrengthIntents

/// Donates the exercise catalogue to Spotlight.
///
/// `IndexedEntity` conformance only describes an entity; it does not index anything. The app has to
/// hand the entities to CoreSpotlight, which is what this does. Best-effort: a Spotlight failure
/// never affects the catalogue, a session or an intent.
enum ExerciseSpotlightIndexer {
    private static let logger = Logger(
        subsystem: "com.georgesdibpersonalteam.StrengthApp",
        category: "intents"
    )

    static func index(_ exercises: [ExerciseOption]) async {
        guard !exercises.isEmpty else { return }
        let entities = exercises.map { ExerciseEntity(id: $0.id, name: $0.display) }
        do {
            try await CSSearchableIndex.default().indexAppEntities(entities)
            logger.debug("Indexed \(entities.count, privacy: .public) exercises for Spotlight")
        } catch {
            logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
