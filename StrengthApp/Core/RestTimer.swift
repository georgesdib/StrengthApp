import Combine
import Foundation
import SwiftUI

@MainActor
final class RestTimerModel: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isComplete = false

    private var ticker: Task<Void, Never>?

    var isRunning: Bool { endDate != nil && !isComplete }

    func start(seconds: Int) {
        guard seconds > 0 else { return }
        ticker?.cancel()
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
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
        isComplete = false
    }

    func dismiss() {
        ticker?.cancel()
        ticker = nil
        endDate = nil
        remainingSeconds = 0
        isComplete = false
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

    var body: some View {
        if timer.endDate != nil {
            HStack(spacing: 12) {
                Image(systemName: timer.isComplete ? "checkmark.circle.fill" : "timer")
                    .foregroundStyle(timer.isComplete ? .green : .orange)
                Text(timer.isComplete ? "Rest complete" : "Rest \(Self.format(timer.remainingSeconds))")
                    .font(.headline)
                Spacer()
                if !timer.isComplete {
                    Button("+15s") { timer.extend(by: 15) }
                        .font(.footnote)
                }
                Button(timer.isComplete ? "Done" : "Skip") {
                    timer.dismiss()
                }
                .font(.footnote)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rest-timer")
        }
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
