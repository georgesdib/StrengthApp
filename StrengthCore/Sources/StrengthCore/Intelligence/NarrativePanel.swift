import SwiftUI

/// Renders the opt-in on-device explanation for one envelope.
///
/// It never substitutes for the deterministic review: when the model is unavailable, fails or
/// produces an ungrounded answer, the review above stays exactly as it was and this panel says why.
public struct NarrativePanel: View {
    private let context: NarrativeContext
    private let generator: any NarrativeGenerating

    @State private var phase: Phase = .idle

    private enum Phase {
        case idle
        case loading
        case result(GeneratedNarrative)
        case message(String)
    }

    public init(context: NarrativeContext, generator: any NarrativeGenerating) {
        self.context = context
        self.generator = generator
    }

    public var body: some View {
        let availability = generator.availability()
        VStack(alignment: .leading, spacing: 8) {
            if availability.isAvailable {
                switch phase {
                case .idle, .message:
                    Button(buttonTitle) { Task { await generate() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("explain-training")
                    if case .message(let message) = phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                    Button("Regenerate") { Task { await generate() } }
                        .font(.footnote)
                        .accessibilityIdentifier("regenerate-explanation")
                }
                Text("Generated on this iPhone; nothing is sent to a server and nothing is saved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                if case .unavailable(let reason) = availability {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var buttonTitle: String {
        context.kind == .weeklyReview ? "Explain this week" : "Explain the last four weeks"
    }

    private func generate() async {
        phase = .loading
        do {
            phase = .result(try await generator.generate(context))
        } catch {
            phase = .message(
                (error as? LocalizedError)?.errorDescription
                    ?? "The explanation could not be generated."
            )
        }
    }
}
