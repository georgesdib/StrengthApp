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
    @Published private(set) var spikeStatus: String?

    /// The app decides when a configuration change may be applied (contract §7.8: not while a
    /// session is active or work is queued).
    var canApplyConfig: () -> Bool = { true }
    /// A plan revision pushed by the phone over WatchConnectivity.
    var onExecutionPayload: (([String: Any]) -> Void)?
    /// The plan-only cache delivered by file, used for a start with no connection.
    var onPlanCache: ((WatchPlanCache) -> Void)?

    private let store: WatchCredentialStore
    private var session: WCSession?
    private var deferredContext: [String: Any]?
    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0
    /// The latest rest the phone has not been told about yet, kept while WatchConnectivity is
    /// still activating.
    private var pendingRest: WatchRestSnapshot?

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
        flushPendingRest()
    }

    /// Sends the open rest to the phone, which mirrors it as a Live Activity. A queued user-info
    /// transfer survives an unreachable or sleeping phone; the latest state is kept and re-sent
    /// once the session is active.
    nonisolated static var planCacheURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("StrengthWatch", isDirectory: true)
            .appendingPathComponent("plan-cache.json")
    }

    nonisolated static func cachedPlan() -> WatchPlanCache? {
        guard let data = try? Data(contentsOf: planCacheURL) else { return nil }
        return try? JSONDecoder().decode(WatchPlanCache.self, from: data)
    }

    var isPhoneReachable: Bool { session?.isReachable ?? false }

    private var lastSentStatus: (String?, String?, Int, String, Bool)?

    func sendStatus(_ status: WatchWorkoutStatus) {
        let key = (status.workoutId, status.sessionId, status.pendingCount,
                   status.phase, status.finishAcknowledged)
        guard lastSentStatus == nil
                || lastSentStatus! != key else {
            return
        }
        guard let session, session.activationState == .activated,
              let message = status.message else { return }
        lastSentStatus = key
        session.transferUserInfo(message)
    }

    func sendRest(_ snapshot: WatchRestSnapshot) {
        guard let session, session.activationState == .activated else {
            pendingRest = snapshot
            return
        }
        pendingRest = nil
        if let message = snapshot.message {
            session.transferUserInfo(message)
        }
    }

    private func flushPendingRest() {
        guard let snapshot = pendingRest,
              let session, session.activationState == .activated else { return }
        pendingRest = nil
        if let message = snapshot.message {
            session.transferUserInfo(message)
        }
    }

    /// Applies a configuration change that was deferred while the session was busy.
    func retryDeferredConfig() {
        guard let context = deferredContext, canApplyConfig() else { return }
        process(context)
        sendAcknowledgement()
    }

    /// WP8 spike: a reachable-phone round trip carrying a request id.
    func testConnectivity() {
        spikeStatus = nil
        guard let session, session.activationState == .activated else {
            spikeStatus = "WatchConnectivity is not active."
            return
        }
        guard session.isReachable else {
            spikeStatus = "Open the iPhone app to make it reachable."
            return
        }
        let requestID = UUID().uuidString.lowercased()
        let started = Date()
        session.sendMessage(
            ["kind": "spike", "request_id": requestID],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    let echoed = reply["request_id"] as? String
                    self?.spikeStatus = echoed == requestID
                        ? "iPhone replied in \(elapsed) ms."
                        : "iPhone replied with the wrong request id."
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in self?.spikeStatus = error.localizedDescription }
            }
        )
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
        // The scene mapping is independent of the credential policy: it must land even while a
        // home-server change is deferred until the running session is finished and synced.
        WatchSceneAutomation.shared.store(start: credential.startScene, end: credential.endScene)
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

extension WatchSessionController: WatchRelayTransport {
    func send(_ request: WatchRelayRequest) async throws -> WatchRelayResponse {
        guard let session, session.activationState == .activated else {
            throw NSError(
                domain: "StrengthWatch.Relay",
                code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey: "WatchConnectivity is not active."
                ]
            )
        }
        guard session.isReachable else {
            throw NSError(
                domain: "StrengthWatch.Relay",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Open the iPhone app to relay this set. It will retry when the phone is reachable."
                ]
            )
        }
        guard let encoded = WatchRelayCoding.encodeRequest(request) else {
            throw NSError(
                domain: "StrengthWatch.Relay",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The relay request could not be encoded."]
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(
                ["kind": "relay", "request": encoded],
                replyHandler: { reply in
                    guard (reply["kind"] as? String) == "relay_reply",
                          let value = reply["response"] as? String,
                          let response = WatchRelayCoding.decodeResponse(value),
                          response.requestId == request.requestId else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "StrengthWatch.Relay",
                                code: 3,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "The iPhone returned an invalid relay response."
                                ]
                            )
                        )
                        return
                    }
                    continuation.resume(returning: response)
                },
                errorHandler: { error in
                    continuation.resume(throwing: error)
                }
            )
        }
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
                self.flushPendingRest()
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
            if let mapping = WatchSceneMapping.decode(userInfo) {
                // The phone's scene choice has its own channel, so it lands even when the
                // credential context has not changed.
                WatchSceneAutomation.shared.store(start: mapping.start, end: mapping.end)
                return
            }
            self?.onExecutionPayload?(userInfo)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        let source = file.fileURL
        let destination = Self.planCacheURL
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            let data = try Data(contentsOf: destination)
            let cache = try JSONDecoder().decode(WatchPlanCache.self, from: data)
            Task { @MainActor in self.onPlanCache?(cache) }
        } catch {
            return
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.sendAcknowledgement()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let kind = message["kind"] as? String
        if kind == "spike" {
            replyHandler([
                "kind": "spike_reply",
                "request_id": message["request_id"] as? String ?? "",
            ])
        } else {
            replyHandler(["kind": "unsupported"])
        }
    }
}
