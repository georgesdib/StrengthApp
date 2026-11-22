import Foundation
import StrengthCore

/// Owns one recording at a time.
///
/// Off by default and DEBUG-gated: no shipping UI turns it on, and production must not
/// accumulate sensor files. The study enables it deliberately, then exports the files.
///
/// Not actor-isolated on purpose: `end()` is called from the End-set button action and
/// `begin()` from the main-actor execution controller, and both must run synchronously so the
/// capture window matches the set window. State is lock-guarded; the published properties are
/// only touched from those UI-thread call sites.
final class WatchMotionCapture: ObservableObject {
    static let shared = WatchMotionCapture()

    static let enabledKey = "watchMotionEnabled"

    @Published private(set) var isRecording = false
    @Published private(set) var lastSaved: URL?
    @Published private(set) var lastSummary: String?
    @Published private(set) var exportedNames: Set<String> = []

    private let store = MotionRecordingStore(directory: MotionRecordingStore.defaultDirectory())
    private let sampler = WatchMotionSampler()
    private let lock = NSLock()
    private var recorder: MotionRecorder?
    /// Keeps the app alive outside a workout. Without an active workout session watchOS suspends
    /// the app as soon as the wrist drops and the screen turns off, and the sample stream dies —
    /// which is exactly what happened to the squat captures. Ended without saving: this is not a
    /// recorded workout.
    private let liveness = WatchHealthKitRecorder()

    static var isEnabled: Bool {
#if DEBUG
        UserDefaults.standard.bool(forKey: enabledKey)
#else
        false
#endif
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    var recordings: [URL] { store.recordings() }

    func load(_ url: URL) -> MotionSetRecording? {
        try? store.load(url)
    }

    func delete(_ url: URL) {
        try? store.delete(url)
        refreshExportState()
    }

    func markExported(_ url: URL) {
        try? store.markExported(url)
        refreshExportState()
    }

    func isExported(_ url: URL) -> Bool {
        exportedNames.contains(url.lastPathComponent)
    }

    /// Deletes only recordings already exported and older than the backstop window.
    @discardableResult
    func purgeExported() -> Int {
        let removed = store.purgeExported().count
        refreshExportState()
        return removed
    }

    func refreshExportState() {
        exportedNames = Set(
            store.recordings()
                .filter { store.exportedAt($0) != nil }
                .map { $0.lastPathComponent }
        )
    }

    /// Starts a recording that belongs to no workout. The identity is local only: the analysis
    /// pairs these files with the LPT by hand, and the Python tool reads the same schema.
    func beginStandalone(label: String, axis: MotionAxis) {
        guard Self.isEnabled else { return }
        Task { try? await liveness.begin(at: Date()) }
        let counter = UserDefaults.standard.integer(forKey: "motionAdhocCounter") + 1
        UserDefaults.standard.set(counter, forKey: "motionAdhocCounter")
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        begin(context: MotionCaptureContext(
            workoutId: "adhoc",
            exerciseId: trimmed.isEmpty ? "adhoc" : trimmed,
            planItemIndex: nil,
            setOrdinal: counter,
            axis: axis,
            startedAt: Date()
        ))
    }

    func begin(context: MotionCaptureContext) {
        guard Self.isEnabled else { return }
        lock.lock()
        let already = recorder != nil
        lock.unlock()
        guard !already else { return }
        guard sampler.isAvailable else {
            lastSummary = "Motion sensor unavailable."
            return
        }
        let recorder = MotionRecorder(context: context, nominalRateHz: 100)
        let started = sampler.start { batch in
            recorder.append(batch)
        }
        guard started else {
            lastSummary = "Motion sensor unavailable."
            return
        }
        lock.lock()
        self.recorder = recorder
        lock.unlock()
        isRecording = true
        lastSummary = nil
    }

    /// Stops sampling and writes the file. Called at End set, before the network call, so a
    /// failed upload never costs the recording.
    func end() {
        lock.lock()
        let recorder = self.recorder
        self.recorder = nil
        lock.unlock()
        guard let recorder else { return }
        sampler.stop()
        isRecording = false
        Task { await liveness.endWithoutSaving() }

        let recording = recorder.finish()
        guard !recording.samples.isEmpty else {
            lastSummary = "No samples captured."
            return
        }
        do {
            let url = try store.save(recording)
            lastSaved = url
            refreshExportState()
            lastSummary = recording.gap.isHealthy
                ? "\(recording.samples.count) samples, no gaps"
                : "gaps: \(recording.gap.gaps), dropped \(Int(recording.gap.droppedFraction * 100))%"
        } catch {
            lastSummary = "Could not save: \(error.localizedDescription)"
        }
    }
}
