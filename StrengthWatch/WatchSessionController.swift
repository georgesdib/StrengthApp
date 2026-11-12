import Combine
import Foundation
import StrengthCore
import WatchConnectivity

@MainActor
final class WatchSessionController: NSObject, ObservableObject {
    enum State: Equatable {
        case waiting
        case ready(host: String)
        case revoked
        case unavailable(String)
    }

    @Published private(set) var state: State = .waiting
    @Published private(set) var lastError: String?

    /// The app decides when a configuration change may be applied (contract §7.8: not while a
    /// session is active or work is queued).
    var canApplyConfig: () -> Bool = { true }
    /// A plan revision pushed by the phone over WatchConnectivity.
    var onExecutionPayload: (([String: Any]) -> Void)?

    private let store: WatchCredentialStore
    private var session: WCSession?
    private var deferredContext: [String: Any]?
    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0

    init(store: WatchCredentialStore = WatchCredentialStore()) {
        self.store = store
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else {
            state = .unavailable("WatchConnectivity is unavailable.")
            return
        }
        guard session == nil else {
            refreshState()
            return
        }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        refreshState()
    }

    func sceneBecameActive() {
        if let session, session.activationState == .activated {
            process(session.receivedApplicationContext)
            sendAcknowledgement()
        }
        retryDeferredConfig()
    }

    /// Applies a configuration change that was deferred while the session was busy.
    func retryDeferredConfig() {
        guard let context = deferredContext, canApplyConfig() else { return }
        process(context)
        sendAcknowledgement()
    }

    /// Called by the 6.3 API layer after a 401/403. The token is wiped immediately; the next
    /// acknowledgement asks the phone for a new credential.
    func markCredentialsMissing() {
        store.markCredentialsMissing()
        refreshState()
        sendAcknowledgement()
    }

    private func process(_ context: [String: Any]) {
        guard !context.isEmpty,
              let credential = try? WatchCredentialContext(dictionary: context),
              (try? credential.validated()) != nil else {
            return
        }
        // Defer a home-server change while this watch has a session to finish and sync.
        if let stored = store.stored,
           stored.homeBaseURL != credential.homeBaseURL,
           !canApplyConfig() {
            deferredContext = context
            return
        }
        deferredContext = nil
        do {
            _ = try store.apply(credential)
            lastError = nil
            refreshState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshState() {
        guard let stored = store.stored else {
            state = .waiting
            return
        }
        if stored.revoked {
            state = .revoked
        } else if store.hasToken {
            state = .ready(host: URL(string: stored.homeBaseURL)?.host ?? stored.homeBaseURL)
        } else {
            state = .waiting
        }
    }

    private func sendAcknowledgement() {
        guard let session, session.activationState == .activated,
              let acknowledgement = store.acknowledgement() else {
            return
        }
        do {
            try session.updateApplicationContext(acknowledgement.dictionary)
            retryAttempts = 0
            cancelRetry()
            store.markAcknowledged()
            lastError = nil
        } catch {
            lastError = "Could not acknowledge the iPhone. Keep both apps open and try again."
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard retryAttempts < 3 else { return }
        cancelRetry()
        let delay = [2, 10, 30][retryAttempts]
        retryAttempts += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sendAcknowledgement()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }
}

extension WatchSessionController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if activationState == .activated {
                self.process(session.receivedApplicationContext)
                self.sendAcknowledgement()
            }
            self.refreshState()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            self.process(applicationContext)
            self.sendAcknowledgement()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        Task { @MainActor [weak self] in
            self?.onExecutionPayload?(userInfo)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.sendAcknowledgement()
        }
    }
}
