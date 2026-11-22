import Foundation

/// File storage for captured sets.
///
/// One JSON file per set, in the app container. Nothing is uploaded: the study exports files
/// deliberately and production discards them on a bounded schedule.
public struct MotionRecordingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Documents/Motion — visible to a debug export and removed with the app.
    public static func defaultDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Motion", isDirectory: true)
    }

    public func save(_ recording: MotionSetRecording) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(for: recording)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(recording).write(to: url, options: .atomic)
        return url
    }

    public func recordings() -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .sorted { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
    }

    public func load(_ url: URL) throws -> MotionSetRecording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MotionSetRecording.self, from: Data(contentsOf: url))
    }

    public func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private func uniqueURL(for recording: MotionSetRecording) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: recording.context.startedAt)
        let exercise = recording.context.exerciseId
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let base = "motion-\(stamp)-\(exercise)-set\(recording.context.setOrdinal)"
        var candidate = directory.appendingPathComponent("\(base).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).json")
            suffix += 1
        }
        return candidate
    }
}
