import SwiftUI
import StrengthCore

struct ExerciseLibraryView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    private var filtered: [ExerciseOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.exerciseCatalogue }
        return model.exerciseCatalogue.filter {
            $0.display.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || ($0.pattern?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        List {
            if let error = model.exerciseCatalogueError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Try again") {
                        Task { await model.loadExerciseCatalogue(force: true) }
                    }
                }
            }

            if model.exerciseCatalogue.isEmpty, model.isLoadingExerciseCatalogue {
                HStack {
                    Spacer()
                    ProgressView("Loading exercises…")
                    Spacer()
                }
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No exercises",
                    systemImage: "magnifyingglass",
                    description: Text("Try another search.")
                )
            } else {
                Section {
                    ForEach(filtered) { option in
                        NavigationLink {
                            ExerciseDetailView(
                                model: model,
                                exerciseId: option.id,
                                display: option.display
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.display)
                                HStack(spacing: 8) {
                                    if let pattern = option.pattern {
                                        Text(pattern.replacingOccurrences(of: "_", with: " ").capitalized)
                                    }
                                    Text(option.id)
                                        .font(.caption2.monospaced())
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("exercise-library-\(option.id)")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(filtered.count) exercises. The catalogue is cached on this phone; use Refresh to reload it.")
                        if let cachedAt = model.exerciseCatalogueCachedAt {
                            Text("Offline cache from \(cachedAt.formatted(date: .abbreviated, time: .shortened)). Refresh when online.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Exercise Library")
        .searchable(text: $search, prompt: "Search exercises")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.loadExerciseCatalogue(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoadingExerciseCatalogue)
                .accessibilityLabel("Refresh exercise catalogue")
            }
        }
        .task { await model.loadExerciseCatalogue() }
    }
}
