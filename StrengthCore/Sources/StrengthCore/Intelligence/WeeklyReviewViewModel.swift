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

    /// A natural label for the loaded week; falls back to the ISO pair.
    public var weekLabel: String {
        guard let envelope else { return "—" }
        return WeeklyReviewDates.weekLabel(
            start: envelope.period.start, end: envelope.period.end
        ) ?? "\(envelope.period.start) to \(envelope.period.end)"
    }
}

public enum WeeklyReviewDates {
    /// Shift an ISO date by whole days. Navigation only; not a training calculation.
    public static func shift(_ iso: String, byDays days: Int) -> String? {
        guard let date = parse(iso),
              let shifted = Calendar(identifier: .gregorian).date(
                  byAdding: .day, value: days, to: date
              ) else { return nil }
        return formatter("yyyy-MM-dd").string(from: shifted)
    }

    /// "2–8 November 2026" or "28 September – 4 October 2026". Presentation only.
    public static func weekLabel(start: String, end: String) -> String? {
        guard let first = parse(start), let last = parse(end) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let sameMonth = calendar.component(.month, from: first) == calendar.component(.month, from: last)
            && calendar.component(.year, from: first) == calendar.component(.year, from: last)
        let endText = formatter("d MMMM yyyy").string(from: last)
        if sameMonth {
            return "\(calendar.component(.day, from: first))–\(endText)"
        }
        return "\(formatter("d MMMM").string(from: first)) – \(endText)"
    }

    private static func parse(_ iso: String) -> Date? {
        let parser = formatter("yyyy-MM-dd")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: iso)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}
