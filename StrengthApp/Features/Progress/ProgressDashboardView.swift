import SwiftUI
import StrengthCore

struct ProgressDashboardView: View {
    @ObservedObject var model: AppModel
    @State private var weeks = 8

    var body: some View {
        NavigationStack {
            List {
                if let error = model.progressError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Try again") {
                            Task { await model.loadProgress(weeks: weeks) }
                        }
                    }
                }

                Section {
                    Picker("Window", selection: $weeks) {
                        ForEach([4, 8, 12, 26, 52], id: \.self) { value in
                            Text("\(value) weeks").tag(value)
                        }
                    }
                    .onChange(of: weeks) { _, value in
                        Task { await model.loadProgress(weeks: value) }
                    }
                }

                if let progress = model.progress {
                    Section("Coverage") {
                        LabeledContent("Sessions", value: "\(progress.coverage.sessions)")
                        LabeledContent("With session RPE", value: "\(progress.coverage.withSrpe)")
                        LabeledContent("Coverage", value: String(format: "%.1f%%", progress.coverage.pct))
                    }

                    Section("Performance") {
                        LabeledContent("Observations", value: "\(progress.performance.n)")
                        if let latest = progress.performance.latest {
                            LabeledContent("Latest ratio", value: String(format: "%.2f on %@", latest.ratio, latest.date))
                        } else {
                            Text("No comparable performance points in this window.")
                                .foregroundStyle(.secondary)
                        }
                        if let median = progress.performance.medianRatio {
                            LabeledContent("Median ratio", value: String(format: "%.2f", median))
                        }
                        ForEach(progress.performance.points.suffix(5)) { point in
                            HStack {
                                Text(point.date)
                                Spacer()
                                Text(String(format: "%.2f", point.ratio))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }

                    Section("Weekly volume") {
                        if progress.volume.isEmpty {
                            Text("No volume rows in this window.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(progress.volume) { row in
                                HStack {
                                    Text(row.pattern.replacingOccurrences(of: "_", with: " ").capitalized)
                                    Spacer()
                                    Text(String(format: "%.1f sets", row.average))
                                        .foregroundStyle(.secondary)
                                    Text(row.status)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    Section("Attendance") {
                        LabeledContent("Window", value: "\(progress.attendance.from) to \(progress.attendance.to)")
                        LabeledContent("Completed", value: "\(progress.attendance.completed)")
                        if let target = progress.attendance.target {
                            LabeledContent("Target", value: "\(target)")
                        }
                        if let pct = progress.attendance.pct {
                            LabeledContent("Completion", value: String(format: "%.1f%%", pct))
                        }
                        if let note = progress.attendance.note, !note.isEmpty {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    Section("Back symptom") {
                        if let level = progress.back.level {
                            LabeledContent("Level", value: "\(level)")
                            LabeledContent("Date", value: progress.back.date ?? "—")
                        } else {
                            Text("No recent back-symptom reading.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let note = progress.note, !note.isEmpty {
                        Section {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if model.isLoadingProgress {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading progress…")
                            Spacer()
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No progress data yet",
                            systemImage: "chart.line.uptrend.xyaxis",
                            description: Text("Completed sessions and readiness days will appear here.")
                        )
                    }
                }
            }
            .navigationTitle("Progress")
            .refreshable { await model.loadProgress(weeks: weeks) }
            .task {
                if !model.hasLoadedProgress {
                    await model.loadProgress(weeks: weeks)
                }
            }
        }
    }
}
