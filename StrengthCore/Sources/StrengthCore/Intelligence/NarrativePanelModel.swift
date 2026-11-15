import Combine
import Foundation

@MainActor
public final class NarrativePanelModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loading
        case result(GeneratedNarrative)
        case message(String)

        public static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case (.result(let a), .result(let b)):
                return a.headline == b.headline && a.observations == b.observations
            case (.message(let a), .message(let b)): return a == b
            default: return false
            }
        }
    }

    public private(set) var context: NarrativeContext
    private let generator: any NarrativeGenerating
    public var generatorAvailability: NarrativeAvailability { generator.availability() }
    @Published public private(set) var phase: Phase = .idle

    public init(context: NarrativeContext, generator: any NarrativeGenerating) {
        self.context = context
        self.generator = generator
    }

    public func generate() async {
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
