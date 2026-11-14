import Combine
import Foundation
import StrengthCore

@MainActor
final class WatchTodayController: ObservableObject {
    @Published private(set) var state: WatchTodayState = .loading
    @Published private(set) var serverDate: String?
    @Published private(set) var isRefreshing = false

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

    func credentialsUnavailable() {
        lastPlan = nil
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
            let snapshot = try await service.fetch(session: session)
            serverDate = snapshot.serverDate
            if case .ready(let plan) = snapshot.state {
                lastPlan = plan
            } else {
                lastPlan = nil
            }
            state = snapshot.state
        } catch let api as APIError where api.isAuthenticationFailure {
            store.markCredentialsMissing()
            lastPlan = nil
            state = .missingCredentials
            onCredentialsMissing()
        } catch let api as APIError {
            if case .transport = api {
                state = .offline(lastPlan)
            } else {
                state = .unavailable(api.errorDescription ?? "The plan could not be loaded.")
            }
        } catch {
            state = .offline(lastPlan)
        }
    }
}
