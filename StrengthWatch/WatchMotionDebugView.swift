import StrengthCore
import SwiftUI

/// Debug-only listing and export of captured sets.
///
/// Nothing here is visible in a release build. Retention is export-aware: an unexported file is
/// the only copy and is never removed automatically, however old it is.
struct WatchMotionDebugView: View {
    @ObservedObject private var capture = WatchMotionCapture.shared
    @State private var files: [URL] = []
    @State private var cleanupNote: String?

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
                if let cleanupNote {
                    Text(cleanupNote)
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
                    row(url)
                }
                .onDelete { offsets in
                    for index in offsets {
                        capture.delete(files[index])
                    }
                    reload()
                }
            } header: {
                Text("Recordings")
            } footer: {
                Text("Swipe to delete. Exported files are removed after 30 days; unexported files are kept until you delete them.")
                    .font(.system(size: 9))
            }

            if !capture.exportedNames.isEmpty {
                Section {
                    Button("Clean up exported") {
                        let removed = capture.purgeExported()
                        cleanupNote = removed == 0
                            ? "Nothing old enough to remove yet."
                            : "Removed \(removed) exported file(s)."
                        reload()
                    }
                    .font(.caption2)
                }
            }
        }
        .navigationTitle("Motion")
        .onAppear {
            capture.purgeExported()
            reload()
        }
        .onChange(of: capture.lastSaved) { _, _ in reload() }
    }

    private func row(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(url.lastPathComponent)
                .font(.caption2)
                .lineLimit(2)
            if let recording = capture.load(url) {
                Text(verbatim: "\(recording.samples.count) samples · \(recording.context.axis?.rawValue ?? "-")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ShareLink(item: url) {
                    Text("Share")
                        .font(.caption2)
                }
                if capture.isExported(url) {
                    Text("exported")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                } else {
                    Button("Mark exported") {
                        capture.markExported(url)
                        reload()
                    }
                    .font(.system(size: 9))
                }
            }
        }
    }

    private func reload() {
        files = capture.recordings
        capture.refreshExportState()
    }
}
