import Foundation

/// A body-aware idempotency token.
///
/// The same exact body keeps the same UUID so a retry can replay the original request. A
/// different body always gets a new UUID, so an edited form is a new operation rather than an
/// accidental conflict. Reset only after a definitive success.
public struct OperationKey<Body: Equatable> {
    public private(set) var key: String
    public private(set) var body: Body?

    public init(key: String = UUID().uuidString.lowercased()) {
        self.key = key
        self.body = nil
    }

    public mutating func use(_ body: Body) -> String {
        if let current = self.body, current == body {
            return key
        }
        key = UUID().uuidString.lowercased()
        self.body = body
        return key
    }

    public mutating func acknowledged() {
        key = UUID().uuidString.lowercased()
        body = nil
    }
}
