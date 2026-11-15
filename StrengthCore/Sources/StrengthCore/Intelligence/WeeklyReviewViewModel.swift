import Combine
import Foundation

/// Loads one weekly-review envelope and steps between weeks.
///
/// The date arithmetic here moves the requested week window; it never touches a training value.
@MainActor
public final class WeeklyReviewViewModel: ObservableObject {
    public typealias Loader = @MainActor (String?) async throws -> IntelligenceEnvelope

    @Published public private(set) var envelope: IntelligenceEnvelope?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoading = false

    private let loader: Loader
    private var requestedWeekEnd: String?

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        do {
            envelope = try await loader(requestedWeekEnd)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The weekly review could not be loaded."
        }
        isLoading = false
    }

    public func step(byWeeks weeks: Int) async {
        guard let current = envelope?.period.end,
              let shifted = WeeklyReviewDates.shift(current, byDays: weeks * 7) else { return }
        requestedWeekEnd = shifted
        await load()
    }
}

public enum WeeklyReviewDates {
    /// Shift an ISO date by whole days. Navigation only; not a training calculation.
    public static func shift(_ iso: String, byDays days: Int) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso),
              let shifted = Calendar(identifier: .gregorian).date(
                  byAdding: .day, value: days, to: date
              ) else { return nil }
        return parser.string(from: shifted)
    }
}
