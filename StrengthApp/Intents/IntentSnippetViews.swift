import StrengthIntents
import SwiftUI

/// Snippet cards. Each takes a value-type digest and no app state, so the same view can be hosted by
/// Siri today and by a `CardSnippet` after the 27.3 adoption pass (plan §7.6).

struct OverviewSnippetView: View {
    let digest: OverviewDigest

    var body: some View {
        SnippetCard(title: "Training overview", subtitle: digest.windowWeeks.map { "Last \($0) weeks" }) {
            ForEach(digest.lines.prefix(4), id: \.label) { line in
                SnippetFactRow(label: line.label, value: line.value)
            }
            if digest.lines.isEmpty {
                Text("Not enough data in this window yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct LastWorkoutSnippetView: View {
    let summary: LastWorkoutSummary?

    var body: some View {
        SnippetCard(title: "Last workout", subtitle: summary?.occurredOn) {
            if let summary {
                SnippetFactRow(
                    label: "Duration",
                    value: summary.durationMin.map { LastWorkoutSummary.minutesText($0) } ?? "not recorded"
                )
                SnippetFactRow(
                    label: "Working sets",
                    value: summary.workingSets.map(String.init) ?? "not recorded"
                )
                if let lifts = summary.mainLifts, !lifts.isEmpty {
                    SnippetFactRow(label: "Main lifts", value: lifts.prefix(2).joined(separator: ", "))
                }
            } else {
                Text("No completed workouts yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProgressionSnippetView: View {
    let name: String
    let direction: String?
    let changeKg: Double?
    let sessions: Int?

    var body: some View {
        SnippetCard(title: "Progression", subtitle: name) {
            if let direction {
                SnippetFactRow(label: "Trend", value: direction.capitalized)
            }
            if let changeKg {
                SnippetFactRow(
                    label: "Change",
                    value: (changeKg < 0 ? "-" : "+") + String(format: "%.1f kg", abs(changeKg))
                )
            }
            if let sessions {
                SnippetFactRow(label: "Sessions", value: String(sessions))
            }
            if direction == nil && changeKg == nil && sessions == nil {
                Text("Not enough comparable sessions for a trend yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WeeklyReviewSnippetView: View {
    let digest: WeeklyReviewDigest

    var body: some View {
        SnippetCard(title: "Weekly review", subtitle: digest.weekStart) {
            if let completed = digest.completedSessions {
                SnippetFactRow(
                    label: "Sessions",
                    value: digest.targetSessions.map { "\(completed) of \($0)" } ?? String(completed)
                )
            }
            if let sets = digest.workingSets {
                SnippetFactRow(label: "Working sets", value: String(sets))
            }
            ForEach(digest.progression.prefix(2), id: \.display) { row in
                SnippetFactRow(
                    label: row.display,
                    value: row.changeKg.map { String(format: "%+.1f kg", $0) } ?? (row.direction ?? "no change")
                )
            }
        }
    }
}

// MARK: - Shared chrome

private struct SnippetCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
    }
}

private struct SnippetFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }
}
