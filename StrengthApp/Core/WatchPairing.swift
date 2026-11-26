import Combine
import Foundation
import StrengthCore
import WatchConnectivity

@MainActor
protocol WatchConnectivitySessionDelegate: AnyObject {
    func watchConnectivityDidChange()
    func watchConnectivityDidReceive(_ context: [String: Any])
    func watchConnectivityDidReceiveMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    )
    /// A queued user-info delivery from the watch: the rest mirror and the plan payloads.
    func watchConnectivityDidReceiveUserInfo(_ userInfo: [String: Any])
}

extension WatchConnectivitySessionDelegate {
    func watchConnectivityDidReceiveUserInfo(_ userInfo: [String: Any]) {}
}

@MainActor
protocol WatchConnectivitySession: AnyObject {
    var delegate: WatchConnectivitySessionDelegate? { get set }
    var isSupported: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activationState: WCSessionActivationState { get }
    var receivedApplicationContext: [String: Any] { get }
    var isReachable: Bool { get }
    func activate()
    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    )
    func updateApplicationContext(_ context: [String: Any]) throws
    /// Queued delivery for content that must not be dropped when the watch is unreachable.
    /// Used for execution payloads; the credential handshake keeps the single-slot
    /// application context (contract §10.2).
    func transferUserInfo(_ userInfo: [String: Any])
    /// Queued file delivery for content that can exceed the WatchConnectivity message and
    /// application-context limits (the plan and its load catalogue).
    func transferFile(_ fileURL: URL, metadata: [String: Any])
}

/// Thin adapter over WCSession. Keeping it behind a protocol lets the handoff logic run in
/// tests without a paired watch or a live WatchConnectivity session.
@MainActor
final class LiveWatchConnectivitySession: NSObject, WatchConnectivitySession, WCSessionDelegate {
    /// One adapter for the process. The app delegate activates it at launch, before the SwiftUI
    /// scene exists, so a background wake can receive a queued user-info transfer.
    static let shared = LiveWatchConnectivitySession()

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
    var isReachable: Bool { session?.isReachable ?? false }

    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        guard let session, session.activationState == .activated else {
            errorHandler?(WatchConnectivityError.unavailable)
            return
        }
        session.sendMessage(message, replyHandler: replyHandler, errorHandler: errorHandler)
    }

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

    func transferUserInfo(_ userInfo: [String: Any]) {
        session?.transferUserInfo(userInfo)
    }

    func transferFile(_ fileURL: URL, metadata: [String: Any]) {
        session?.transferFile(fileURL, metadata: metadata)
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

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            self.delegate?.watchConnectivityDidReceiveMessage(
                message, replyHandler: replyHandler
            )
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            // The workout Live Activity is handled independently of the pairing coordinator: a
            // background launch may not have created the app model yet.
            WatchRestReceiver.shared.handleUserInfo(userInfo)
            self.delegate?.watchConnectivityDidReceiveUserInfo(userInfo)
        }
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
        case configuring
        case paired
        case revoked
    }

    @Published private(set) var phase: Phase = .unavailable("Apple Watch support is unavailable.")
    @Published private(set) var link: PairedWatch?
    @Published private(set) var watchStatus: WatchWorkoutStatus?
    private(set) var localSetMap = LocalSetMap()
    private var lastPushedPlanKey: String?
    /// The phone's committed workout, so an incoming watch set can be merged against it.
    var currentWorkout: (() -> WorkoutDetail?)?
    /// Applied after a relayed watch write so the phone's merged view stays current and a
    /// consumed phone-side plan preview cannot outlive the start that used it.
    var onRelayedWorkout: ((WorkoutDetail) -> Void)?
    /// Called when the watch reports its pending work, so a synced watch can settle an open
    /// reconciliation window instead of leaving it open for the full seven days.
    var onWatchStatus: ((WatchWorkoutStatus) -> Void)?
    @Published private(set) var isMinting = false
    @Published private(set) var isRevoking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var connectivitySpikeStatus: String?

    private let client: IOSAPIClient
    private let store: PairedStore
    private let connectivity: WatchConnectivitySession?
    private var session: IOSSession?
    private var homeBaseURL: String?
    private var pendingToken: String?
    private var retryTask: Task<Void, Never>?
    private var mintTask: Task<Void, Never>?
    private var retryAttempts = 0
    private var autoMintAttempts = 0
    private var configRebaselineAttempts = 0
    private var isActive = false
    /// The scene mapping last handed to WatchConnectivity in this launch.
    private var sentSceneMapping: (start: String?, end: String?)?

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

    /// Runs the WP8 WatchConnectivity spike: a reachable-watch round trip carrying an id.
    func testConnectivity() {
        connectivitySpikeStatus = nil
        guard isActive, let link, !link.revoked, let connectivity else {
            connectivitySpikeStatus = "Pair the watch and open both apps first."
            return
        }
        guard connectivity.activationState == .activated else {
            connectivitySpikeStatus = "WatchConnectivity is not active yet."
            return
        }
        guard connectivity.isReachable else {
            connectivitySpikeStatus = "Watch is not reachable. Open the watch app."
            return
        }
        let requestID = UUID().uuidString.lowercased()
        let started = Date()
        connectivity.sendMessage(
            ["kind": "spike", "request_id": requestID],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    let echoed = reply["request_id"] as? String
                    self?.connectivitySpikeStatus = echoed == requestID
                        ? "Watch replied in \(elapsed) ms."
                        : "Watch replied with the wrong request id."
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.connectivitySpikeStatus = error.localizedDescription
                }
            }
        )
    }

    var statusText: String {
        switch phase {
        case .unavailable(let message): return message
        case .notPaired: return "Not paired"
        case .waiting: return "Waiting for Apple Watch"
        case .configuring: return "Updating Apple Watch…"
        case .paired: return "Paired"
        case .revoked: return "Revoked"
        }
    }

    var lastAckText: String? {
        guard let value = link?.lastAckAt, !value.isEmpty else { return nil }
        return value
    }

    var watchDeviceID: String? { link?.deviceID }

    var isWatchReachable: Bool { connectivity?.isReachable ?? false }

    /// Whether this phone could still be missing the watch's events for a workout.
    func watchMayHavePendingWork(for workoutId: String) -> Bool {
        guard link?.revoked != true, let watchDeviceID else { return false }
        if let status = watchStatus {
            return status.hasPendingWork(for: workoutId)
        }
        // No heartbeat yet and no live connection: the phone cannot know what the watch has,
        // so it names it as pending. A synced watch settles the window explicitly.
        return !isWatchReachable
    }

    /// Delivers the plan and catalogue by file. Application context stays reserved for the
    /// credential handshake (contract §10.2), and plan + catalogue can exceed its 65 KB ceiling.
    @discardableResult
    func pushPlanCache(_ issued: IssuedPlanResponse) -> Bool {
        guard isActive,
              link?.revoked != true,
              let connectivity,
              connectivity.activationState == .activated,
              connectivity.isWatchAppInstalled,
              let executionID = issued.executionID,
              !executionID.isEmpty else {
            return false
        }
        let key = issued.issuedPlanId + ":" + executionID
        guard lastPushedPlanKey != key else { return true }
        let cache = WatchPlanCache(
            issuedPlanId: issued.issuedPlanId,
            executionId: executionID,
            forDate: issued.forDate,
            sessionType: issued.sessionType,
            expiresAt: issued.expiresAt,
            plan: issued.plan,
            loadCatalogue: issued.loadCatalogue,
            warnings: issued.warnings
        )
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("plan-cache-\(executionID).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(cache).write(to: url, options: [.atomic])
            connectivity.transferFile(url, metadata: ["kind": "plan_cache", "execution_id": executionID])
            lastPushedPlanKey = key
            return true
        } catch {
            return false
        }
    }

    func start(session: IOSSession, homeBaseURL: String?) {
        self.session = session
        self.homeBaseURL = homeBaseURL
        self.isActive = true
        retryAttempts = 0
        configRebaselineAttempts = 0
        connectivity?.delegate = self
        refreshAvailability()
        updatePhase()
        processReceivedContext()
        if let connectivity, connectivity.activationState != .activated {
            connectivity.activate()
        } else if link?.revoked == true {
            Task { await sendRevokedContext() }
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
        updatePhase()
        if let connectivity, connectivity.activationState != .activated {
            connectivity.activate()
        }
    }

    /// Sends the frozen plan snapshot and the phone-authored execution view to the watch. Queued
    /// rather than latest-wins so a nudge is not dropped while the watch is unreachable; the watch
    /// merges the execution view by watermark and ignores a plan that is not newer
    /// (contract §10.2, §10.5; DEC-RESOLVER-23). A workout the server did not stamp with a
    /// plan revision cannot be pushed coherently. Best effort: the watch also refreshes on
    /// foreground and after each set, so a lost nudge is recoverable.
    @discardableResult
    func pushExecution(_ workout: WorkoutDetail, execution: ExecutionView? = nil) -> Bool {
        guard isActive,
              link?.revoked != true,
              let connectivity,
              connectivity.activationState == .activated,
              connectivity.isWatchAppInstalled,
              let revision = workout.planRevision,
              let payload = RemoteExecutionPayload(
                workout: workout,
                revision: revision,
                execution: execution
              ),
              let json = payload.encodedString() else {
            return false
        }
        connectivity.transferUserInfo(["execution": json])
        return true
    }

    func stop() {
        isActive = false
        cancelRetry()
        mintTask?.cancel()
        mintTask = nil
        pendingToken = nil
        session = nil
        connectivity?.delegate = nil
    }

    func reset() {
        stop()
        link = nil
        retryAttempts = 0
        autoMintAttempts = 0
        configRebaselineAttempts = 0
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
        guard let session = homeSession else {
            errorMessage = "Pair this iPhone with the server and set a valid Home Server first."
            updatePhase()
            return
        }
        isMinting = true
        autoMintAttempts = 0
        configRebaselineAttempts = 0
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
        guard !isMinting, !isRevoking, let current = link else { return }
        guard let session = homeSession else {
            errorMessage = "Set a valid Home Server before revoking the watch."
            updatePhase()
            return
        }
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
        retryAttempts = 0
        configRebaselineAttempts = 0
        updatePhase()
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
        configRebaselineAttempts = 0
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
        guard let session = homeSession, let current = link, !current.revoked else { return }
        do {
            let response = try await client.devices(session: session)
            let active = response.devices.first {
                $0.kind == "watch"
                    && $0.revokedAt == nil
                    && $0.parentDeviceId == session.deviceID
            }
            guard let active else {
                if isWatchPaired, autoMintAttempts < 2 {
                    requestFreshMint()
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
                next.homeBaseURL = nil
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

    private func mintForExistingLink(allowPendingToken: Bool = false) async {
        guard !isMinting else { return }
        guard allowPendingToken || pendingToken == nil else { return }
        guard let session = homeSession else {
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
            guard isActive else { return }
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
            status: .ready,
            startScene: WorkoutAutomation.shared.startScene?.jsonString,
            endScene: WorkoutAutomation.shared.endScene?.jsonString
        )
        do {
            try connectivity.updateApplicationContext(context.dictionary)
            scheduleRetry()
        } catch {
            errorMessage = message(for: error)
            scheduleRetry()
        }
    }

    /// Re-sends the credential context and pushes the scene mapping on its own channel, so a
    /// changed choice reaches the watch even though the credential slot itself may be unchanged.
    func syncSceneMapping() async {
        sendSceneMapping(force: true)
        await sendCredential()
    }

    /// The scene mapping as a queued user-info transfer. It survives an unreachable watch and is
    /// re-delivered when the watch app next runs, which is what a preference needs.
    func sendSceneMapping(force: Bool = false) {
        guard let connectivity else { return }
        guard connectivity.activationState == .activated else {
            // The activation callback re-sends the mapping, so nothing is queued here.
            connectivity.activate()
            return
        }
        let start = WorkoutAutomation.shared.startScene?.jsonString
        let end = WorkoutAutomation.shared.endScene?.jsonString
        // A reachability change must not queue the same preference again and again.
        if !force, let sent = sentSceneMapping, sent.start == start, sent.end == end { return }
        sentSceneMapping = (start, end)
        connectivity.transferUserInfo(WatchSceneMapping.message(start: start, end: end))
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
              let current = link else {
            return
        }
        if ack.deviceID != current.deviceID {
            handleDifferentDevice(ack, current: current)
        } else {
            handleSameDevice(ack, current: current)
        }
    }

    private func handleSameDevice(
        _ ack: WatchAcknowledgement,
        current: PairedWatch
    ) {
        switch ack.status {
        case .ready:
            if ack.ackEpoch < current.epoch {
                // Same lineage, but the watch's acknowledgement is older than the current
                // credential. If we are already paired, this is a delayed/duplicate ack and
                // must not trigger another mint. Only an unacknowledged current credential
                // needs the deliberate replacement.
                guard current.ackEpoch < current.epoch, pendingToken == nil else { return }
                requestFreshMint()
                return
            }
            var next = current
            if ack.ackEpoch > current.epoch {
                // Same watch identity, newer server lineage state. Accept the watch's
                // persisted epoch; the token remains on the watch.
                next.epoch = ack.ackEpoch
            }
            next.ackEpoch = ack.ackEpoch
            next.configVersion = ack.configVersion
            next.homeBaseURL = ack.homeBaseURL
            next.lastAckAt = Self.timestamp()
            next.revoked = false
            link = next
            store.watchLink = next
            pendingToken = nil
            retryAttempts = 0
            cancelRetry()
            errorMessage = nil
            reconcileConfiguration(ack)
        case .missing:
            guard !current.revoked else { return }
            if ack.ackEpoch < current.epoch {
                guard current.ackEpoch < current.epoch, pendingToken == nil else { return }
                requestFreshMint()
                return
            }
            requestFreshMint(allowPendingToken: true)
        case .revoked:
            guard ack.ackEpoch >= current.epoch else { return }
            var next = current
            next.epoch = max(current.epoch, ack.ackEpoch)
            next.revoked = true
            next.ackEpoch = 0
            link = next
            store.watchLink = next
            pendingToken = nil
            cancelRetry()
            updatePhase()
        }
    }

    private func handleDifferentDevice(
        _ ack: WatchAcknowledgement,
        current: PairedWatch
    ) {
        switch ack.status {
        case .ready, .missing:
            // Epochs from a different device lineage are not comparable. A tokenless probe
            // cannot replace a valid credential; mint one fresh epoch for this phone and
            // send a token-bearing context. Repeated stale acknowledgements are ignored while
            // that handoff is in flight or after the bounded automatic attempts are spent.
            guard !current.revoked,
                  pendingToken == nil,
                  !isMinting else {
                return
            }
            requestFreshMint()
        case .revoked:
            // A revocation for an unrelated watch must never change this phone's link.
            return
        }
    }

    private func requestFreshMint(allowPendingToken: Bool = false) {
        guard mintTask == nil, autoMintAttempts < 2 else {
            if mintTask == nil {
                errorMessage = "Could not recover the Apple Watch credential. Tap Pair Apple Watch again."
                updatePhase()
            }
            return
        }
        mintTask = Task { [weak self] in
            await self?.mintForExistingLink(allowPendingToken: allowPendingToken)
            self?.mintTask = nil
        }
    }

    private func reconcileConfiguration(_ ack: WatchAcknowledgement) {
        let desiredVersion = store.watchConfigVersion
        let desiredURL = validHomeBaseURL()?.absoluteString
        let urlMatches: Bool
        if let acknowledgedURL = ack.homeBaseURL, let desiredURL {
            urlMatches = acknowledgedURL == desiredURL
        } else {
            // Older watch builds did not include the URL; configVersion equality remains the
            // compatibility fallback. The next acknowledgement after this build includes it.
            urlMatches = true
        }

        if ack.configVersion > desiredVersion {
            // The watch is ahead (for example after a phone reinstall). Raise the phone's
            // desired version above it so future Home changes are not ignored as stale.
            guard configRebaselineAttempts < 2 else {
                errorMessage = "Could not reconcile the Apple Watch configuration. Tap Pair Apple Watch again."
                updatePhase()
                return
            }
            configRebaselineAttempts += 1
            store.watchConfigVersion = ack.configVersion + 1
            updatePhase()
            Task { await sendCredential() }
            return
        }
        if ack.configVersion < desiredVersion {
            guard configRebaselineAttempts < 2 else {
                errorMessage = "Could not reconcile the Apple Watch configuration. Tap Pair Apple Watch again."
                updatePhase()
                return
            }
            configRebaselineAttempts += 1
            updatePhase()
            Task { await sendCredential() }
            return
        }
        guard urlMatches else {
            guard configRebaselineAttempts < 2 else {
                errorMessage = "Could not reconcile the Apple Watch configuration. Tap Pair Apple Watch again."
                updatePhase()
                return
            }
            configRebaselineAttempts += 1
            store.bumpWatchConfigVersion()
            updatePhase()
            Task { await sendCredential() }
            return
        }
        configRebaselineAttempts = 0
        updatePhase()
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
            return
        }
        guard link.ackEpoch == link.epoch else {
            phase = .waiting
            return
        }
        guard let desiredURL = validHomeBaseURL()?.absoluteString else {
            phase = .unavailable("Set a valid Home Server before pairing the watch.")
            return
        }
        let homeMatches = link.homeBaseURL == nil || link.homeBaseURL == desiredURL
        if link.configVersion != store.watchConfigVersion || !homeMatches {
            phase = .configuring
        } else {
            phase = .paired
        }
    }

    private var homeSession: IOSSession? {
        guard let session, let home = validHomeBaseURL() else { return nil }
        return IOSSession(
            baseURL: home,
            token: session.token,
            deviceID: session.deviceID
        )
    }

    /// Commits one watch operation with the phone's credential. The watch token that travelled
    /// with the request is not used for execution writes; the watch keeps it for reads only.
    private func relay(_ request: WatchRelayRequest) async -> WatchRelayResponse {
        do {
            let baseURL = try IOSAPIClient.validatedBaseURL(request.baseURL)
            let watchSession = IOSSession(
                baseURL: baseURL, token: request.token, deviceID: request.deviceID
            )
            // The phone is the only writer. Its own session commits execution writes; the
            // watch token is kept only for reads such as the bootstrap clock.
            let commitSession: IOSSession
            if request.operation == .bootstrap {
                commitSession = watchSession
            } else {
                guard let phoneSession = homeSession else {
                    throw APIError.transport("The iPhone session is unavailable.")
                }
                commitSession = phoneSession
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            func payload<T: Decodable>(_ type: T.Type) throws -> T {
                guard let data = request.payload else {
                    throw APIError.decoding
                }
                return try decoder.decode(T.self, from: data)
            }
            func encode<T: Encodable>(_ value: T) -> Data? {
                try? encoder.encode(value)
            }
            switch request.operation {
            case .bootstrap:
                let value = try await client.bootstrap(session: watchSession)
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .start:
                guard let issuedPlanId = request.issuedPlanId,
                      let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "start relay is incomplete", fields: [:])
                }
                let startBody = try? payload(StartWorkoutRequest.self)
                let value = try await client.startWorkout(
                    issuedPlanId: issuedPlanId,
                    executionId: startBody?.executionId,
                    startedAt: startBody?.startedAt,
                    session: commitSession,
                    idempotencyKey: key
                )
                onRelayedWorkout?(value)
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .addSet:
                guard let workoutId = request.workoutId, let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "set relay is incomplete", fields: [:])
                }
                var body = try payload(AddSetRequest.self)
                // The watch captured it; the phone remains the authenticated committer.
                body = body.withOriginDeviceId(request.deviceID)
                if let index = body.setIndex {
                    let existing = (currentWorkout?()?.sets ?? []).compactMap { set -> (String, Int)? in
                        guard let value = set.setIndex else { return nil }
                        return (set.exerciseId, value)
                    }
                    let provisional = ProvisionalSet(
                        deviceId: request.deviceID ?? "watch",
                        localSetId: key,
                        exerciseId: body.exerciseId,
                        setIndex: index,
                        planItemIndex: body.planItemIndex,
                        performedAt: body.performedAt
                    )
                    let merged = SetMerge.renumber(
                        [provisional],
                        existing: existing.map { (exerciseId: $0.0, setIndex: $0.1) }
                    )
                    if let assigned = merged.first?.setIndex, assigned != index {
                        body = body.withSetIndex(assigned)
                    }
                }
                let value = try await client.addSet(
                    workoutId: workoutId,
                    body: body,
                    session: commitSession,
                    idempotencyKey: key,
                    journaling: false
                )
                if let created = value.sets?
                    .filter({ $0.exerciseId == body.exerciseId })
                    .max(by: { ($0.setId ?? 0) < ($1.setId ?? 0) }),
                   let setId = created.setId {
                    localSetMap.record(
                        deviceId: request.deviceID ?? "watch",
                        localSetId: key,
                        setId: setId
                    )
                }
                onRelayedWorkout?(value)
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .updateSet:
                guard let workoutId = request.workoutId, let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "correction relay is incomplete", fields: [:])
                }
                let value = try await client.updateSet(
                    workoutId: workoutId,
                    body: try payload(UpdateSetRequest.self),
                    session: commitSession,
                    idempotencyKey: key
                )
                onRelayedWorkout?(value)
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .removeSet:
                guard let workoutId = request.workoutId, let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "removal relay is incomplete", fields: [:])
                }
                let value = try await client.removeSet(
                    workoutId: workoutId,
                    body: try payload(RemoveSetRequest.self),
                    session: commitSession,
                    idempotencyKey: key
                )
                onRelayedWorkout?(value)
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .executionEvents:
                guard let workoutId = request.workoutId, let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "event relay is incomplete", fields: [:])
                }
                let value = try await client.submitExecutionEvents(
                    workoutId: workoutId,
                    events: try payload(ExecutionEventsRequest.self).events,
                    session: commitSession,
                    idempotencyKey: key
                )
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .finish:
                guard let workoutId = request.workoutId, let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "finish relay is incomplete", fields: [:])
                }
                let value = try await client.completeWorkout(
                    workoutId: workoutId,
                    body: try payload(CompleteWorkoutRequest.self),
                    session: commitSession,
                    idempotencyKey: key,
                    journaling: false
                )
                onRelayedWorkout?(value)
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .abandon:
                guard let workoutId = request.workoutId, let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "abandon relay is incomplete", fields: [:])
                }
                let value = try await client.abandonWorkout(
                    workoutId: workoutId, session: commitSession, idempotencyKey: key
                )
                onRelayedWorkout?(value)
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            case .rateForm:
                guard let workoutId = request.workoutId, let key = request.idempotencyKey else {
                    throw APIError.http(status: 400, message: "form relay is incomplete", fields: [:])
                }
                let value = try await client.rateForm(
                    workoutId: workoutId,
                    body: try payload(FormRatingRequest.self),
                    session: commitSession,
                    idempotencyKey: key,
                    journaling: false
                )
                return WatchRelayResponse(
                    requestId: request.requestId, ok: true, payload: encode(value)
                )
            }
        } catch {
            return WatchRelayResponse(
                requestId: request.requestId,
                ok: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func validHomeBaseURL() -> URL? {
        guard let homeBaseURL, !homeBaseURL.isEmpty else { return nil }
        return try? IOSAPIClient.validatedBaseURL(homeBaseURL)
    }

    private func message(for error: Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .transport:
                return "Could not reach the Home Server. Apple Watch operations use Home only; Away is never used."
            case .unauthorized, .forbidden:
                return "The Home Server rejected this iPhone's credential. Pair the iPhone again."
            default:
                break
            }
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
    func watchConnectivityDidReceiveMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let kind = message["kind"] as? String
        if kind == "relay",
           let encoded = message["request"] as? String,
           let request = WatchRelayCoding.decodeRequest(encoded) {
            Task { @MainActor in
                let response = await self.relay(request)
                replyHandler([
                    "kind": "relay_reply",
                    "response": WatchRelayCoding.encodeResponse(response) ?? "",
                ])
            }
            return
        }
        guard kind == "spike" else {
            replyHandler(["kind": "unsupported"])
            return
        }
        replyHandler([
            "kind": "spike_reply",
            "request_id": message["request_id"] as? String ?? "",
        ])
    }

    func watchConnectivityDidChange() {
        refreshAvailability()
        updatePhase()
        if connectivity?.activationState == .activated {
            sendSceneMapping()
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

    func watchConnectivityDidReceiveUserInfo(_ userInfo: [String: Any]) {
        if let status = WatchWorkoutStatus.decode(userInfo) {
            watchStatus = status
            onWatchStatus?(status)
            return
        }
        // Rests are handled by WatchRestReceiver at the session boundary, before the coordinator,
        // so they are still delivered when the app launches in the background.
    }
}
