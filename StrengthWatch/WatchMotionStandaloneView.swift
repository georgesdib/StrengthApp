import StrengthCore
import SwiftUI

/// Records a set with no workout, no plan and no server.
///
/// It is the same sampler and the same JSON as the in-workout capture — only the trigger is
/// different — so the Mac-side analysis reads these files unchanged. The axis is chosen here
/// because there is no plan item to supply it.
struct WatchMotionStandaloneView: View {
    @ObservedObject private var capture = WatchMotionCapture.shared
    @State private var axis: MotionAxis = .vertical
    @State private var label = "squat"
    @State private var startedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if capture.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: elapsed(to: context.date))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .accessibilityIdentifier("watch-motion-elapsed")
                    }
                    Text("Recording \(label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Stop") {
                        capture.end()
                        startedAt = nil
                    }
                    .tint(.red)
                    .accessibilityIdentifier("watch-motion-stop")
                } else {
                    TextField("Label", text: $label)
                        .accessibilityIdentifier("watch-motion-label")
                    Picker("Axis", selection: $axis) {
                        Text("Vertical").tag(MotionAxis.vertical)
                        Text("Horizontal").tag(MotionAxis.horizontal)
                    }
                    .accessibilityIdentifier("watch-motion-axis")
                    Button("Start") {
                        capture.beginStandalone(label: label, axis: axis)
                        if capture.isRecording { startedAt = Date() }
                    }
                    .tint(.green)
                    .accessibilityIdentifier("watch-motion-start")
                }

                if let summary = capture.lastSummary, !capture.isRecording {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Saved like any other recording. Nothing is uploaded.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Record")
    }

    private func elapsed(to now: Date) -> String {
        let start = startedAt ?? now
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
