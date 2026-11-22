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

    private let store = MotionRecordingStore(directory: MotionRecordingStore.defaultDirectory())
    private let sampler = WatchMotionSampler()
    private let lock = NSLock()
    private var recorder: MotionRecorder?

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

        let recording = recorder.finish()
        guard !recording.samples.isEmpty else {
            lastSummary = "No samples captured."
            return
        }
        do {
            let url = try store.save(recording)
            lastSaved = url
            lastSummary = recording.gap.isHealthy
                ? "\(recording.samples.count) samples, no gaps"
                : "gaps: \(recording.gap.gaps), dropped \(Int(recording.gap.droppedFraction * 100))%"
        } catch {
            lastSummary = "Could not save: \(error.localizedDescription)"
        }
    }
}
