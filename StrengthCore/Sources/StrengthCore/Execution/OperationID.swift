import CryptoKit
import Foundation

/// Deterministic `Idempotency-Key` values for the watch engine's mutations.
///
/// The contract requires every mutation to send `Idempotency-Key: <uuid>`, and the server
/// replays the stored response for a key it has already seen. The engine retries start and
/// abandon from its offline ladder, including after a relaunch, so the key must be stable across
/// attempts: minting a fresh UUID per attempt would start a second workout after a timeout.
/// Deriving the key from the operation name keeps it stable, and hashing keeps it a UUID whatever
/// shape the id has.
public enum OperationID {
    /// App-specific prefix so these hashes cannot collide with another client's derived keys.
    private static let namespace = "com.georgesdibpersonalteam.StrengthApp.watch-operation."

    /// A stable, lowercase, RFC 4122-shaped UUID for one logical operation.
    public static func derived(_ name: String) -> String {
        var digest = Array(SHA256.hash(data: Data((namespace + name).utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x80   // version 8: application-defined derivation
        digest[8] = (digest[8] & 0x3F) | 0x80   // RFC 4122 variant
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let digits = Array(hex)
        return [
            String(digits[0..<8]),
            String(digits[8..<12]),
            String(digits[12..<16]),
            String(digits[16..<20]),
            String(digits[20..<32]),
        ].joined(separator: "-")
    }
}
