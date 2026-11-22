import StrengthCore
import SwiftUI

/// Debug-only listing and export of captured sets.
///
/// The files are the study's raw material. Nothing here is visible in a release build.
struct WatchMotionDebugView: View {
    @ObservedObject private var capture = WatchMotionCapture.shared
    @State private var files: [URL] = []

    var body: some View {
        List {
            Section {
                Toggle("Capture sets", isOn: Binding(
                    get: { WatchMotionCapture.isEnabled },
                    set: { WatchMotionCapture.setEnabled($0) }
                ))
                .accessibilityIdentifier("watch-motion-toggle")
                if let summary = capture.lastSummary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if files.isEmpty {
                    Text("No recordings yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.caption2)
                            .lineLimit(2)
                        if let recording = capture.load(url) {
                            Text(verbatim: "\(recording.samples.count) samples · \(recording.context.axis?.rawValue ?? "-")")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        ShareLink(item: url) {
                            Text("Share")
                                .font(.caption2)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        capture.delete(files[index])
                    }
                    files = capture.recordings
                }
            }
        }
        .navigationTitle("Motion")
        .onAppear { files = capture.recordings }
        .onChange(of: capture.lastSaved) { _, _ in files = capture.recordings }
    }
}
