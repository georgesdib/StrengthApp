import Combine
import Foundation
import StrengthCore

@MainActor
final class WatchTodayController: ObservableObject {
    @Published private(set) var state: WatchTodayState = .loading
    @Published private(set) var serverDate: String?
    /// Today's readiness, carried by the same plan read. Kept through an offline failure so the
    /// screen still answers "how am I today"; cleared only when the watch loses its credential.
    @Published private(set) var readiness: WatchReadinessSummary?
    @Published private(set) var isRefreshing = false

    /// Backstop, not the primary timeout: the client cancels a request at 10 s and retries a
    /// transient failure, so two full attempts fit inside this budget. It fires only when
    /// watchOS never lets the request finish, which is what left the screen on "Loading plan…".
    static let refreshDeadline: Double = 22

    private let store: WatchCredentialStore
    private let service: WatchTodayService
    private let onCredentialsMissing: @MainActor () -> Void
    private var lastPlan: WatchPlanSummary?

    init(
        store: WatchCredentialStore = WatchCredentialStore(),
        onCredentialsMissing: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.service = WatchTodayService(client: IOSAPIClient())
        self.onCredentialsMissing = onCredentialsMissing
    }

    func start() {
        Task { await refresh() }
    }

    /// Names the server the watch tried before the reason, because "cannot reach it" is a very
    /// different problem when the address itself is stale or refused by the system.
    private func offlineDetail(_ baseURL: String, _ error: APIError?) -> String {
        WatchOfflineDetail.make(baseURL: baseURL, reason: error?.errorDescription)
    }

    func credentialsUnavailable() {
        lastPlan = nil
        readiness = nil
        state = .missingCredentials
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let stored = store.stored,
              let token = store.loadToken(),
              let baseURL = URL(string: stored.homeBaseURL) else {
            credentialsUnavailable()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if lastPlan == nil {
            state = .loading
        }
        let session = IOSSession(
            baseURL: baseURL,
            token: token,
            deviceID: stored.deviceID
        )
        do {
            let snapshot = try await AsyncDeadline.run(seconds: Self.refreshDeadline) {
                try await self.service.fetch(session: session)
            }
            serverDate = snapshot.serverDate
            readiness = snapshot.readiness
            if case .ready(let plan) = snapshot.state {
                lastPlan = plan
            } else {
                lastPlan = nil
            }
            state = snapshot.state
        } catch is AsyncDeadline.Exceeded {
            state = .offline(lastPlan, detail: WatchOfflineDetail.make(
                baseURL: stored.homeBaseURL,
                reason: "No response within \(Int(Self.refreshDeadline)) seconds."
            ))
        } catch let api as APIError where api.isAuthenticationFailure {
            store.markCredentialsMissing()
            lastPlan = nil
            state = .missingCredentials
            onCredentialsMissing()
        } catch let api as APIError {
            if case .transport = api {
                state = .offline(lastPlan, detail: offlineDetail(stored.homeBaseURL, api))
            } else {
                state = .unavailable(api.errorDescription ?? "The plan could not be loaded.")
            }
        } catch {
            state = .offline(lastPlan, detail: offlineDetail(stored.homeBaseURL, nil))
        }
    }
}
