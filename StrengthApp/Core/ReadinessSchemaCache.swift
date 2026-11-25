import Foundation
import StrengthCore

struct CachedReadinessSchema: Codable, Equatable {
    let serverURL: String
    let fetchedAt: Date
    let schema: ReadinessSchema
}

/// Disk cache for the effective readiness schema. The schema is a form contract, not training
/// authority: an offline entry may still be written and journaled, but a metric added to the
/// registry after this file was written cannot be shown until the server is reachable again.
struct ReadinessSchemaCache {
    let fileURL: URL

    init(fileURL: URL = ReadinessSchemaCache.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthApp", isDirectory: true)
            .appendingPathComponent("readiness-schema.json")
    }

    func load(serverURL: String) -> CachedReadinessSchema? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedReadinessSchema.self, from: data),
              cached.serverURL == serverURL else {
            return nil
        }
        return cached
    }

    func save(
        serverURL: String,
        schema: ReadinessSchema,
        fetchedAt: Date = Date()
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            CachedReadinessSchema(
                serverURL: serverURL,
                fetchedAt: fetchedAt,
                schema: schema
            )
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
