import Combine
import Foundation
import StrengthCore
import WatchConnectivity

@MainActor
protocol WatchConnectivitySessionDelegate: AnyObject {
    func watchConnectivityDidChange()
    func watchConnectivityDidReceive(_ context: [String: Any])
}

@MainActor
protocol WatchConnectivitySession: AnyObject {
    var delegate: WatchConnectivitySessionDelegate? { get set }
    var isSupported: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activationState: WCSessionActivationState { get }
    var receivedApplicationContext: [String: Any] { get }
    func activate()
    func updateApplicationContext(_ context: [String: Any]) throws
}

/// Thin adapter over WCSession. Keeping it behind a protocol lets the handoff logic run in
/// tests without a paired watch or a live WatchConnectivity session.
@MainActor
final class LiveWatchConnectivitySession: NSObject, WatchConnectivitySession, WCSessionDelegate {
    weak var delegate: WatchConnectivitySessionDelegate?
    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    var isSupported: Bool { session != nil }
    var isPaired: Bool { session?.isPaired ?? false }
    var isWatchAppInstalled: Bool { session?.isWatchAppInstalled ?? false }
    var activationState: WCSessionActivationState { session?.activationState ?? .notActivated }
    var receivedApplicationContext: [String: Any] { session?.receivedApplicationContext ?? [:] }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        guard let session else {
            throw WatchConnectivityError.unavailable
        }
        try session.updateApplicationContext(context)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.delegate?.watchConnectivityDidChange() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.delegate?.watchConnectivityDidChange()
            self.session?.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.delegate?.watchConnectivityDidChange() }
    }

    nonisolated func session(_ session: WCSession, watchReachabilityChanged: Bool) {
        Task { @MainActor in self.delegate?.watchConnectivityDidChange() }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in self.delegate?.watchConnectivityDidReceive(applicationContext) }
    }
}

enum WatchConnectivityError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Apple Watch connectivity is unavailable."
    }
}

@MainActor
final class WatchPairingCoordinator: ObservableObject {
    enum Phase: Equatable {
        case unavailable(String)
        case notPaired
        case waiting
        case paired
        case revoked
    }

    @Published private(set) var phase: Phase = .unavailable("Apple Watch support is unavailable.")
    @Published private(set) var link: PairedWatch?
    @Published private(set) var isMinting = false
    @Published private(set) var isRevoking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false

    private let client: IOSAPIClient
    private let store: PairedStore
    private let connectivity: WatchConnectivitySession?
    private var session: IOSSession?
    private var homeBaseURL: String?
    private var pendingToken: String?
    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0
    private var autoMintAttempts = 0
    private var isActive = false

    init(
        client: IOSAPIClient,
        store: PairedStore,
        connectivity: WatchConnectivitySession? = nil
    ) {
        self.client = client
        self.store = store
        self.connectivity = connectivity
        self.link = store.watchLink
        connectivity?.delegate = self
        refreshAvailability()
        updatePhase()
    }

    var canPair: Bool {
        guard isWatchPaired, !isMinting, !isRevoking else { return false }
        return validHomeBaseURL() != nil
    }

    var canRevoke: Bool {
        guard let link, !link.revoked, !isRevoking else { return false }
        return true
    }

    var statusText: String {
        switch phase {
        case .unavailable(let message): return message
        case .notPaired: return "Not paired"
        case .waiting: return "Waiting for Apple Watch"
        case .paired: return "Paired"
        case .revoked: return "Revoked"
        }
    }

    var lastAckText: String? {
        guard let value = link?.lastAckAt, !value.isEmpty else { return nil }
        return value
    }

    func start(session: IOSSession, homeBaseURL: String?) {
        self.session = session
        self.homeBaseURL = homeBaseURL
        self.isActive = true
        connectivity?.delegate = self
        refreshAvailability()
        updatePhase()
        processReceivedContext()
        if let connectivity, connectivity.activationState != .activated {
            connectivity.activate()
        } else if link == nil {
            Task { await sendIfNeeded() }
        } else {
            // A tokenless duplicate lets a reinstalled watch ask for credentials again.
            Task { await sendCredential() }
        }
    }

    func updateSession(_ session: IOSSession, homeBaseURL: String?) {
        self.session = session
        self.homeBaseURL = homeBaseURL
        if let connectivity, connectivity.activationState != .activated {
            connectivity.activate()
        }
    }

    func stop() {
        isActive = false
        cancelRetry()
        pendingToken = nil
        session = nil
        connectivity?.delegate = nil
    }

    func reset() {
        stop()
        link = nil
        retryAttempts = 0
        autoMintAttempts = 0
        errorMessage = nil
        updatePhase()
    }

    func pair() async {
        guard !isMinting, !isRevoking else { return }
        guard isWatchPaired else {
            errorMessage = "Pair an Apple Watch with this iPhone first."
            updatePhase()
            return
        }
        guard validHomeBaseURL() != nil else {
            errorMessage = "Set a valid Home Server before pairing the watch."
            updatePhase()
            return
        }
        guard let session else {
            errorMessage = "Pair this iPhone with the server first."
            updatePhase()
            return
        }
        isMinting = true
        errorMessage = nil
        defer {
            isMinting = false
            updatePhase()
        }
        do {
            let minted = try await client.mintWatch(session: session)
            await adopt(minted: minted, manual: true)
        } catch {
            errorMessage = message(for: error)
        }
    }

    func revoke() async {
        guard !isMinting, !isRevoking, let session, let current = link else { return }
        isRevoking = true
        errorMessage = nil
        defer {
            isRevoking = false
            updatePhase()
        }
        do {
            _ = try await client.revokeDevice(deviceId: current.deviceID, session: session)
            await markRevoked(current)
        } catch let error as APIError where Self.isNotFound(error) {
            await markRevoked(current)
        } catch {
            errorMessage = message(for: error)
        }
    }

    func configurationChanged(homeBaseURL: String?) async {
        self.homeBaseURL = homeBaseURL
        guard isActive, let link, !link.revoked else { return }
        if let connectivity, connectivity.activationState == .activated {
            await sendCredential()
        }
    }

    func foreground(session: IOSSession, homeBaseURL: String?) async {
        self.session = session
        self.homeBaseURL = homeBaseURL
        isActive = true
        retryAttempts = 0
        autoMintAttempts = 0
        refreshAvailability()
        if let connectivity, connectivity.activationState != .activated {
            connectivity.activate()
        }
        processReceivedContext()
        if link?.revoked == true {
            await sendRevokedContext()
            updatePhase()
            return
        }
        await reconcileWithServer()
        updatePhase()
        if link == nil {
            await sendIfNeeded()
        } else {
            await sendCredential()
        }
    }

    private func adopt(minted: WatchMintResponse, manual: Bool) async {
        let next = PairedWatch(
            deviceID: minted.device.deviceId,
            label: minted.device.label,
            epoch: minted.device.credentialEpoch ?? 1,
            ackEpoch: 0,
            configVersion: 0,
            revoked: false,
            lastAckAt: nil
        )
        link = next
        store.watchLink = next
        pendingToken = minted.token
        if manual {
            retryAttempts = 0
        }
        updatePhase()
        await sendCredential()
    }

    private func markRevoked(_ current: PairedWatch) async {
        var next = current
        next.revoked = true
        next.ackEpoch = 0
        link = next
        store.watchLink = next
        pendingToken = nil
        cancelRetry()
        updatePhase()
        await sendRevokedContext()
    }

    private func reconcileWithServer() async {
        guard let session, let current = link, !current.revoked else { return }
        do {
            let response = try await client.devices(session: session)
            let active = response.devices.first {
                $0.kind == "watch"
                    && $0.revokedAt == nil
                    && $0.parentDeviceId == session.deviceID
            }
            guard let active else {
                if isWatchPaired, autoMintAttempts < 2 {
                    await mintForExistingLink()
                } else {
                    errorMessage = "The watch is not active on the server. Tap Pair Apple Watch to rotate it."
                }
                return
            }
            let epoch = active.credentialEpoch ?? 0
            var next = current
            if next.deviceID != active.deviceId || next.epoch != epoch {
                next.deviceID = active.deviceId
                next.label = active.label
                next.epoch = epoch
                next.ackEpoch = 0
                next.configVersion = 0
                next.revoked = false
                link = next
                store.watchLink = next
                pendingToken = nil
            }
            updatePhase()
        } catch {
            // A foreground check must not create a watch token when the server is unreachable.
            errorMessage = message(for: error)
        }
    }

    private func mintForExistingLink() async {
        guard let session, !isMinting else { return }
        guard validHomeBaseURL() != nil else {
            errorMessage = "Set a valid Home Server before pairing the watch."
            return
        }
        isMinting = true
        autoMintAttempts += 1
        errorMessage = nil
        defer {
            isMinting = false
            updatePhase()
        }
        do {
            let minted = try await client.mintWatch(session: session)
            await adopt(minted: minted, manual: false)
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func sendIfNeeded() async {
        guard isActive, let link, !link.revoked else { return }
        let needsToken = pendingToken != nil && link.ackEpoch < link.epoch
        let needsConfig = link.configVersion < store.watchConfigVersion
        let needsProbe = pendingToken == nil && link.ackEpoch < link.epoch
        guard needsToken || needsConfig || needsProbe else { return }
        await sendCredential()
    }

    private func sendCredential() async {
        guard isActive, let link, !link.revoked else { return }
        guard let homeBaseURL = validHomeBaseURL() else {
            errorMessage = "Set a valid Home Server before pairing the watch."
            return
        }
        guard let connectivity else {
            errorMessage = "Apple Watch support is unavailable."
            return
        }
        guard connectivity.activationState == .activated else {
            connectivity.activate()
            return
        }
        let context = WatchCredentialContext(
            epoch: link.epoch,
            configVersion: store.watchConfigVersion,
            homeBaseURL: homeBaseURL.absoluteString,
            deviceID: link.deviceID,
            token: pendingToken,
            issuedAt: Self.timestamp(),
            status: .ready
        )
        do {
            try connectivity.updateApplicationContext(context.dictionary)
            scheduleRetry()
        } catch {
            errorMessage = message(for: error)
            scheduleRetry()
        }
    }

    private func sendRevokedContext() async {
        guard let link, let homeBaseURL = validHomeBaseURL(), let connectivity else { return }
        guard connectivity.activationState == .activated else { return }
        let context = WatchCredentialContext(
            epoch: link.epoch,
            configVersion: store.watchConfigVersion,
            homeBaseURL: homeBaseURL.absoluteString,
            deviceID: link.deviceID,
            token: nil,
            issuedAt: Self.timestamp(),
            status: .revoked
        )
        try? connectivity.updateApplicationContext(context.dictionary)
    }

    private func processReceivedContext() {
        guard let context = connectivity?.receivedApplicationContext, !context.isEmpty else { return }
        handle(context)
    }

    private func handle(_ dictionary: [String: Any]) {
        guard let ack = try? WatchAcknowledgement(dictionary: dictionary),
              let current = link,
              ack.deviceID == current.deviceID else {
            return
        }
        switch ack.status {
        case .ready:
            guard ack.ackEpoch == current.epoch else { return }
            var next = current
            next.ackEpoch = ack.ackEpoch
            next.configVersion = ack.configVersion
            next.lastAckAt = Self.timestamp()
            next.revoked = false
            link = next
            store.watchLink = next
            pendingToken = nil
            retryAttempts = 0
            cancelRetry()
            errorMessage = nil
            updatePhase()
            if next.configVersion < store.watchConfigVersion {
                Task { await sendCredential() }
            }
        case .missing:
            guard !current.revoked else { return }
            if autoMintAttempts < 2 {
                Task { await mintForExistingLink() }
            } else {
                errorMessage = "Could not hand credentials to Apple Watch. Tap Pair Apple Watch again."
            }
        case .revoked:
            var next = current
            next.revoked = true
            next.ackEpoch = 0
            link = next
            store.watchLink = next
            pendingToken = nil
            cancelRetry()
            updatePhase()
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
            await self?.sendCredential()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func refreshAvailability() {
        isWatchPaired = connectivity?.isPaired ?? false
        isWatchAppInstalled = connectivity?.isWatchAppInstalled ?? false
    }

    private func updatePhase() {
        guard let connectivity, connectivity.isSupported else {
            phase = .unavailable("Apple Watch support is unavailable.")
            return
        }
        guard connectivity.isPaired else {
            phase = .unavailable("Pair an Apple Watch with this iPhone first.")
            return
        }
        guard let link else {
            phase = .notPaired
            return
        }
        if link.revoked {
            phase = .revoked
        } else if link.ackEpoch >= link.epoch {
            phase = .paired
        } else {
            phase = .waiting
        }
    }

    private func validHomeBaseURL() -> URL? {
        guard let homeBaseURL, !homeBaseURL.isEmpty else { return nil }
        return try? IOSAPIClient.validatedBaseURL(homeBaseURL)
    }

    private func message(for error: Error) -> String {
        if let api = error as? APIError {
            if api.code == "watch_disabled" {
                return "Watch pairing is disabled on the server."
            }
            return api.errorDescription ?? "The watch request failed."
        }
        return error.localizedDescription
    }

    private static func isNotFound(_ error: APIError) -> Bool {
        switch error {
        case .http(let status, _, _): return status == 404
        case .server(let status, let code, _, _, _): return status == 404 || code == "not_found"
        default: return false
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

extension WatchPairingCoordinator: WatchConnectivitySessionDelegate {
    func watchConnectivityDidChange() {
        refreshAvailability()
        updatePhase()
        if connectivity?.activationState == .activated {
            if let context = connectivity?.receivedApplicationContext, !context.isEmpty {
                handle(context)
            }
            if link?.revoked == true {
                Task { await sendRevokedContext() }
            } else if link != nil {
                Task { await sendCredential() }
            } else {
                Task { await sendIfNeeded() }
            }
        }
    }

    func watchConnectivityDidReceive(_ context: [String: Any]) {
        handle(context)
    }
}
