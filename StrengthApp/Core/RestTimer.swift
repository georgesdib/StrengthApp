import Combine
import Foundation
import SwiftUI

struct RestTimerResult: Equatable {
    let startedAt: Date
    let endedAt: Date
    let prescribedSeconds: Int
    let actualSeconds: Int
    let addedSeconds: Int
    let outcome: String
}

@MainActor
final class RestTimerModel: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isComplete = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var prescribedSeconds: Int?
    @Published private(set) var addedSeconds = 0

    private var ticker: Task<Void, Never>?

    var isRunning: Bool { endDate != nil && !isComplete }

    func start(seconds: Int) {
        guard seconds > 0 else { return }
        ticker?.cancel()
        let now = Date()
        startedAt = now
        prescribedSeconds = seconds
        addedSeconds = 0
        endDate = now.addingTimeInterval(TimeInterval(seconds))
        remainingSeconds = seconds
        isComplete = false
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func extend(by seconds: Int) {
        guard let endDate else { return }
        self.endDate = endDate.addingTimeInterval(TimeInterval(seconds))
        remainingSeconds = max(0, remainingSeconds + seconds)
        addedSeconds += seconds
        isComplete = false
    }

    /// Ends the current rest and returns the observed interval. nil means no rest was running.
    func finish(outcome: String = "completed") -> RestTimerResult? {
        guard let startedAt, let prescribedSeconds else { return nil }
        let result = RestTimerResult(
            startedAt: startedAt,
            endedAt: Date(),
            prescribedSeconds: prescribedSeconds,
            actualSeconds: max(0, Int(Date().timeIntervalSince(startedAt))),
            addedSeconds: addedSeconds,
            outcome: outcome
        )
        dismiss()
        return result
    }

    func dismiss() {
        ticker?.cancel()
        ticker = nil
        endDate = nil
        remainingSeconds = 0
        isComplete = false
        startedAt = nil
        prescribedSeconds = nil
        addedSeconds = 0
    }

    private func tick() {
        guard let endDate else { return }
        let remaining = Int(endDate.timeIntervalSinceNow.rounded(.up))
        if remaining <= 0 {
            remainingSeconds = 0
            isComplete = true
            ticker?.cancel()
            ticker = nil
        } else {
            remainingSeconds = remaining
        }
    }
}

struct RestTimerBar: View {
    @ObservedObject var timer: RestTimerModel
    var onFinish: ((RestTimerResult) -> Void)?
    var onExtended: ((Int) -> Void)?
    @State private var reportedCompletion = false

    var body: some View {
        if timer.endDate != nil {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Image(systemName: timer.isComplete ? "checkmark.circle.fill" : "timer")
                        .foregroundStyle(timer.isComplete ? .green : .orange)
                    Text(timer.isComplete ? "Rest complete" : "Rest \(Self.format(timer.remainingSeconds))")
                        .font(.headline)
                    Spacer()
                    if !timer.isComplete {
                        Button("+15s") {
                            timer.extend(by: 15)
                            onExtended?(15)
                        }
                        .font(.footnote)
                    }
                    Button(timer.isComplete ? "Done" : "Skip") {
                        finish(outcome: timer.isComplete ? "completed" : "skipped")
                    }
                    .font(.footnote)
                }
                if let prescribed = timer.prescribedSeconds {
                    Text(timer.addedSeconds > 0
                         ? "Prescribed \(prescribed)s · extended \(timer.addedSeconds)s"
                         : "Prescribed \(prescribed)s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rest-timer")
            .onChange(of: timer.isComplete) { _, complete in
                if complete { finish(outcome: "completed") }
            }
            .onChange(of: timer.startedAt) { _, started in
                if started != nil { reportedCompletion = false }
            }
        }
    }

    private func finish(outcome: String) {
        guard !reportedCompletion,
              let result = timer.finish(outcome: outcome) else { return }
        reportedCompletion = true
        onFinish?(result)
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
