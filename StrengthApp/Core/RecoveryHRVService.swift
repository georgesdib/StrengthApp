import Foundation
import StrengthCore

/// Computes and uploads the recovery-HRV series.
///
/// The series is backfilled once from HealthKit and then updated nightly. Progress is a watermark,
/// so an interrupted backfill resumes on the next launch instead of restarting, and every night is
/// idempotent on the server by its sample id.
@MainActor
final class RecoveryHRVService {
    static let backfillCompleteKey = "recoveryHRV.backfillComplete"
    static let backfillOldestKey = "recoveryHRV.backfillOldest"
    static let serverKey = "recoveryHRV.server"

    private static let pageDays = 180
    private static let horizonYears = 5
    private static let recentDays = 3
    private static let maxSamplesPerRequest = 200

    private let healthKit: any HealthKitReadinessProviding
    private let client: IOSAPIClient
    private let defaults: UserDefaults
    private var isBackfilling = false

    init(
        healthKit: any HealthKitReadinessProviding,
        client: IOSAPIClient,
        defaults: UserDefaults = .standard
    ) {
        self.healthKit = healthKit
        self.client = client
        self.defaults = defaults
    }

    /// A different server has none of this device's history, so the backfill starts again.
    func prepare(for serverURL: String) {
        guard defaults.string(forKey: Self.serverKey) != serverURL else { return }
        defaults.set(serverURL, forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.backfillCompleteKey)
        defaults.removeObject(forKey: Self.backfillOldestKey)
    }

    /// The last few nights, uploaded before the readiness import so its response can show HRV.
    func syncRecent(session: IOSSession, now: Date = Date()) async {
        let calendar = Calendar.current
        let end = now.addingTimeInterval(5 * 60)
        guard let start = calendar.date(byAdding: .day, value: -Self.recentDays, to: end) else {
            return
        }
        guard let nights = try? await healthKit.recoveryNights(from: start, to: end),
              !nights.isEmpty else { return }
        _ = await upload(nights, session: session)
    }

    /// One bounded pass; the watermark only moves after a page uploads cleanly.
    func backfill(session: IOSSession, now: Date = Date()) async {
        guard !isBackfilling, !defaults.bool(forKey: Self.backfillCompleteKey) else { return }
        isBackfilling = true
        defer { isBackfilling = false }
        let calendar = Calendar.current
        guard let floor = calendar.date(byAdding: .year, value: -Self.horizonYears, to: now) else {
            return
        }
        var cursor = defaults.object(forKey: Self.backfillOldestKey)
            .flatMap { $0 as? Double }
            .map(Date.init(timeIntervalSince1970:)) ?? now
        while cursor > floor {
            guard let pageStart = calendar.date(
                byAdding: .day, value: -Self.pageDays, to: cursor
            ) else { return }
            let from = max(pageStart, floor)
            guard let nights = try? await healthKit.recoveryNights(from: from, to: cursor) else {
                return
            }
            if !nights.isEmpty, !(await upload(nights, session: session)) { return }
            cursor = from
            defaults.set(cursor.timeIntervalSince1970, forKey: Self.backfillOldestKey)
        }
        defaults.set(true, forKey: Self.backfillCompleteKey)
    }

    private func upload(_ nights: [RecoveryHRVSample], session: IOSSession) async -> Bool {
        var index = 0
        while index < nights.count {
            let end = min(index + Self.maxSamplesPerRequest, nights.count)
            let chunk = Array(nights[index..<end])
            do {
                _ = try await client.importRecoveryHRV(
                    RecoveryHRVRequest(samples: chunk),
                    session: session,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
            } catch {
                return false
            }
            index = end
        }
        return true
    }
}
