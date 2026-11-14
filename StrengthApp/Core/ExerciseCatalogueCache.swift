import Foundation
import StrengthCore

struct CachedExerciseCatalogue: Codable, Equatable {
    let serverURL: String
    let fetchedAt: Date
    let exercises: [ExerciseOption]
}

/// Disk cache for the exercise picker. The list is a naming/selection aid, never training
/// authority: an offline client may browse and choose an exercise, but plan edits still require
/// the server.
struct ExerciseCatalogueCache {
    let fileURL: URL

    init(fileURL: URL = ExerciseCatalogueCache.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthApp", isDirectory: true)
            .appendingPathComponent("exercise-catalogue.json")
    }

    func load(serverURL: String) -> CachedExerciseCatalogue? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedExerciseCatalogue.self, from: data),
              cached.serverURL == serverURL else {
            return nil
        }
        return cached
    }

    func save(
        serverURL: String,
        exercises: [ExerciseOption],
        fetchedAt: Date = Date()
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            CachedExerciseCatalogue(
                serverURL: serverURL,
                fetchedAt: fetchedAt,
                exercises: exercises
            )
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
