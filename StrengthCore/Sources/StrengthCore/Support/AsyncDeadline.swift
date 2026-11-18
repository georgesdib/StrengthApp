import Foundation

/// Bounds an awaited operation by wall-clock time.
///
/// URLSession cancels a request at its own timeout, but watchOS can leave a request pending well
/// past it when the server is unreachable, and a cancelled view task may never resume. Either
/// case strands a screen on its loading state with no way forward, so the caller gets a bounded
/// failure it can render instead.
public enum AsyncDeadline {
    public struct Exceeded: Error, Equatable {
        public let seconds: Double

        public init(seconds: Double) {
            self.seconds = seconds
        }
    }

    public static func run<T>(
        seconds: Double,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Exceeded(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw Exceeded(seconds: seconds)
            }
            return first
        }
    }
}
