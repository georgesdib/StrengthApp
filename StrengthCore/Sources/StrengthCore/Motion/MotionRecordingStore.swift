import Foundation

/// File storage for captured sets.
///
/// One JSON file per set, in the app container. Nothing is uploaded: the study exports files
/// deliberately and then deletes them.
///
/// Retention is **not** a timer on capture. A recording is the only copy of its data until it
/// has been exported, so an unexported file is never deleted automatically, however old it is.
/// Once exported, a copy exists elsewhere and the watch copy may be purged after a long
/// backstop window. Deleting the irreplaceable copy on a clock would destroy exactly the data
/// that makes re-analysis possible.
public struct MotionRecordingStore: Sendable {
    public let directory: URL
    public static let retentionDays = 30
    private var indexURL: URL { directory.appendingPathComponent(".index.json") }

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
        var index = readIndex()
        index.removeValue(forKey: url.lastPathComponent)
        try writeIndex(index)
    }

    // MARK: - Export bookkeeping

    /// Records that a copy of this recording exists off the watch.
    public func markExported(_ url: URL, at date: Date = Date()) throws {
        var index = readIndex()
        index[url.lastPathComponent] = date
        try writeIndex(index)
    }

    public func exportedAt(_ url: URL) -> Date? {
        readIndex()[url.lastPathComponent]
    }

    /// Deletes exported recordings older than the backstop window and drops stale index rows.
    /// Unexported recordings are never touched.
    @discardableResult
    public func purgeExported(
        now: Date = Date(), retentionDays: Int = MotionRecordingStore.retentionDays
    ) -> [URL] {
        var index = readIndex()
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var removed: [URL] = []
        for filename in index.keys {
            let url = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: url.path) {
                index.removeValue(forKey: filename)
                continue
            }
            guard let exported = index[filename], exported < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url)
                index.removeValue(forKey: filename)
            }
        }
        try? writeIndex(index)
        return removed
    }

    // MARK: - Index

    private func readIndex() -> [String: Date] {
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private func writeIndex(_ index: [String: Date]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: indexURL, options: .atomic)
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
