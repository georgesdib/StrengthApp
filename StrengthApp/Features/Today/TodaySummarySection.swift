import SwiftUI
import StrengthCore

/// The prose block at the top of Today: one factual passage and one encouragement, from the model
/// the athlete configured for chat.
struct TodaySummarySection: View {
    @ObservedObject var model: AppModel
    @StateObject private var summary: TodaySummaryModel

    init(model: AppModel) {
        self.model = model
        _summary = StateObject(wrappedValue: model.makeTodaySummaryModel())
    }

    var body: some View {
        Section {
            longevityBlock
            content
            footer
        } header: {
            Label("Today at a glance", systemImage: "sparkles")
        }
        .task(id: model.todaySummaryFingerprint) {
            await summary.loadIfNeeded(fingerprint: model.todaySummaryFingerprint)
        }
    }

    /// The deterministic half: the numbers, and the sentence that needs no model.
    @ViewBuilder
    private var longevityBlock: some View {
        if let longevity = model.longevity {
            VStack(alignment: .leading, spacing: 4) {
                Text(longevity.headline)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(longevity.vo2maxLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("today-longevity-card")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch summary.phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Writing today's summary…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .ready(let value):
            VStack(alignment: .leading, spacing: 8) {
                Text("Where you stand")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value.overview)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Nudge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value.encouragement)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("today-summary-card")
        case .unavailable(let reason), .failed(let reason):
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(sourceText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await summary.refresh(fingerprint: model.todaySummaryFingerprint) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("today-summary-refresh")
        }
    }

    private var sourceText: String {
        summary.sendsFactsOffDevice
            ? "\(summary.modelLabel) · your facts are sent to \(summary.modelLabel)"
            : "\(summary.modelLabel) · nothing leaves this iPhone"
    }
}
