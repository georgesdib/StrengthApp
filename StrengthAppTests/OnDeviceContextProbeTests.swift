import XCTest
import StrengthCore
#if canImport(FoundationModels) && os(iOS)
import FoundationModels

private final class ProbeProvider: IntelligenceCapabilityProviding, @unchecked Sendable {
    func trainingOverview(asOf: String?, windowWeeks: Int) async throws -> String { "ok" }
    func exerciseProgression(exerciseID: String, windowDays: Int) async throws -> String { "ok" }
    func weeklyReview(weekEnd: String?) async throws -> String { "ok" }
    func sessionDetails(workoutID: String) async throws -> String { "ok" }
    func readinessStatus(from: String, to: String) async throws -> String { "ok" }
    func longevityAssessment(includeTimeInZone: Bool) async throws -> String { "ok" }
}

@available(iOS 27.0, *)
private struct ProbeTool: Tool {
    typealias Arguments = NarrativeToolQuery
    let name: String
    let description: String
    func call(arguments: NarrativeToolQuery) async throws -> String { "ok" }
}

/// Physical-device probe only. Reports which tool variants fit the on-device context.
@MainActor
final class OnDeviceContextProbeTests: XCTestCase {
    func testToolContextBudget() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run on the physical iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["RUN_CONTEXT_PROBE"] == "1" else {
            throw XCTSkip("Set RUN_CONTEXT_PROBE=1 to run the physical-device context probe.")
        }
        guard #available(iOS 27.0, *) else { throw XCTSkip("iOS 27 required.") }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            print("PROBE: model unavailable: \(model.availability)")
            throw XCTSkip("Apple Intelligence not available.")
        }
        print("PROBE: contextSize=\(model.contextSize)")
        print("PROBE: toolCalling=\(model.capabilities.contains(.toolCalling))")
        print("PROBE: guidedGeneration=\(model.capabilities.contains(.guidedGeneration))")

        let base = IntelligenceTools.make(provider: ProbeProvider())
        let extraOne = [ProbeTool(name: "prescription", description: "Read-only current training prescription: exercises, target loads, sets, reps and RIR.")]
        let extraThree = extraOne + [
            ProbeTool(name: "programme_summary", description: "Read-only programme block summary: block name, week, progression intent and state."),
            ProbeTool(name: "adherence", description: "Read-only adherence history: completed vs target sessions over a recent window."),
        ]
        let history = (1...4)
            .map { "Athlete: a short question about training number \($0)." }
            .joined(separator: "\n")
        let shortFacts = (1...20)
            .map { "fact \($0): value \($0)." }
            .joined(separator: "\n")
        let longFacts = (1...60)
            .map { "fact \($0): value \($0)." }
            .joined(separator: "\n")
        let prompt = "Reply with ok.\n" + history + "\nFacts:\n" + shortFacts
        let largePrompt = "Reply with ok.\n" + history + "\nFacts:\n" + longFacts
        let variants: [(String, [any Tool], String)] = [
            ("base5", base, "Reply with ok."),
            ("base5+prescription", base + extraOne, "Reply with ok."),
            ("base5+3", base + extraThree, "Reply with ok."),
            ("base5+3+short-facts", base + extraThree, prompt),
            ("base5+3+large-facts", base + extraThree, largePrompt),
            ("base5+large-facts", base, largePrompt),
        ]
        for (name, tools, prompt) in variants {
            do {
                let session = LanguageModelSession(
                    model: model, tools: tools, instructions: "You are a probe. Do not call tools."
                )
                _ = try await session.respond(to: prompt)
                print("PROBE: \(name)=PASS")
            } catch {
                print("PROBE: \(name)=FAIL \(error.localizedDescription)")
            }
        }
        #endif
    }
}
#endif
