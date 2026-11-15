import SwiftUI

/// Renders the opt-in on-device explanation for one envelope.
///
/// It never substitutes for the deterministic review: when the model is unavailable, fails or
/// produces an ungrounded answer, the review above stays exactly as it was and this panel says why.
public struct NarrativePanel: View {
    @StateObject private var model: NarrativePanelModel

    public init(context: NarrativeContext, generator: any NarrativeGenerating) {
        _model = StateObject(
            wrappedValue: NarrativePanelModel(context: context, generator: generator)
        )
    }

    public var body: some View {
        let availability = model.generatorAvailability
        VStack(alignment: .leading, spacing: 8) {
            if availability.isAvailable {
                switch model.phase {
                case .idle, .message:
                    Button(buttonTitle) { Task { await model.generate() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("explain-training")
                    if case .message(let message) = model.phase {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Writing the explanation…").foregroundStyle(.secondary)
                    }
                case .result(let narrative):
                    Text(narrative.headline).font(.headline)
                    ForEach(Array(narrative.observations.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)").font(.callout)
                    }
                    Label(narrative.limitation, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Regenerate") { Task { await model.generate() } }
                        .font(.footnote)
                        .accessibilityIdentifier("regenerate-explanation")
                }
                Text("Generated on this iPhone; nothing is sent to a server and nothing is saved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if case .unavailable(let reason) = availability {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var buttonTitle: String {
        model.context.kind == .weeklyReview ? "Explain this week" : "Explain the last four weeks"
    }
}
