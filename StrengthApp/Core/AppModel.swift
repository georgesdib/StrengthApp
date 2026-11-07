import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case pairing
        case paired
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var bootstrap: BootstrapResponse?
    @Published private(set) var today: TodayResponse?
    @Published private(set) var sessions: [HistorySession] = []
    @Published private(set) var historyTotal = 0
    @Published private(set) var isPairing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasLoadedHistory = false
    @Published private(set) var device: PairingDevice?
    @Published private(set) var pairedServerURL: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pairingError: String?

    @Published var serverURLText: String
    @Published var pairingCodeText: String = ""
    @Published var pairingLabelText: String

    private let client: IOSAPIClient
    private let tokens: TokenStoring
    private let store: PairedStore
    private let pageSize = 50
    private var session: IOSSession?
    private var historyOffset = 0

    init(
        client: IOSAPIClient? = nil,
        tokens: TokenStoring? = nil,
        store: PairedStore? = nil
    ) {
        let store = store ?? PairedStore()
        self.client = client ?? IOSAPIClient()
        self.tokens = tokens ?? KeychainTokenStore()
        self.store = store
        self.serverURLText = store.serverURL ?? AppConfig.defaultServerURL
        self.pairingLabelText = store.device?.label ?? "iPhone"
    }

    var hasMoreHistory: Bool {
        sessions.count < historyTotal
    }

    var appVersion: String {
        AppConfig.versionText
    }

    // MARK: Lifecycle

    func onLaunch() async {
        guard phase == .loading else { return }
        guard let savedURL = store.serverURL,
              let token = tokens.load(),
              let baseURL = try? IOSAPIClient.validatedBaseURL(savedURL) else {
            phase = .pairing
            return
        }
        session = IOSSession(baseURL: baseURL, token: token)
        device = store.device
        pairedServerURL = baseURL.absoluteString
        serverURLText = baseURL.absoluteString
        if let device { pairingLabelText = device.label }
        phase = .paired
        await refresh()
    }

    // MARK: Pairing

    func pair() async {
        guard !isPairing else { return }
        pairingError = nil
        let baseURL: URL
        let code: String
        let label: String
        do {
            baseURL = try IOSAPIClient.validatedBaseURL(serverURLText)
        } catch {
            pairingError = message(for: error)
            return
        }
        do {
            code = try IOSAPIClient.normalizeCode(pairingCodeText)
        } catch {
            pairingError = message(for: error)
            return
        }
        do {
            label = try IOSAPIClient.normalizeLabel(pairingLabelText)
        } catch {
            pairingError = message(for: error)
            return
        }

        isPairing = true
        defer { isPairing = false }
        do {
            let response = try await client.pair(baseURL: baseURL, code: code, label: label)
            try tokens.save(response.token)
            let paired = PairingDevice(
                deviceID: response.device.deviceId,
                label: response.device.label
            )
            store.serverURL = baseURL.absoluteString
            store.device = paired
            device = paired
            pairedServerURL = baseURL.absoluteString
            serverURLText = baseURL.absoluteString
            pairingLabelText = response.device.label
            pairingCodeText = ""
            session = IOSSession(baseURL: baseURL, token: response.token)
            phase = .paired
            await refresh()
        } catch {
            pairingError = message(for: error)
        }
    }

    // MARK: Reads

    func refresh() async {
        guard let session, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let bootstrapTask = client.bootstrap(session: session)
            async let todayTask = client.today(session: session)
            let (newBootstrap, newToday) = try await (bootstrapTask, todayTask)
            bootstrap = newBootstrap
            today = newToday
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func loadHistory(reset: Bool = false) async {
        guard let session, !isLoadingHistory else { return }
        if reset {
            historyOffset = 0
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await client.history(
                session: session,
                limit: pageSize,
                offset: historyOffset
            )
            historyTotal = page.total
            if reset {
                sessions = page.sessions
            } else {
                sessions.append(contentsOf: page.sessions)
            }
            // The server pages by a stable order; de-duplicating keeps a refresh/load-more race
            // from showing the same session twice.
            var seen = Set<String>()
            sessions = sessions.filter { seen.insert($0.sessionId).inserted }
            historyOffset = sessions.count
            hasLoadedHistory = true
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func loadMoreHistory() async {
        guard hasMoreHistory else { return }
        await loadHistory(reset: false)
    }

    // MARK: Local credential management

    func forgetDevice() {
        forgetLocally(message: nil)
    }

    private func forgetLocally(message: String?) {
        tokens.delete()
        store.device = nil
        device = nil
        session = nil
        bootstrap = nil
        today = nil
        sessions = []
        historyTotal = 0
        historyOffset = 0
        hasLoadedHistory = false
        pairedServerURL = store.serverURL
        phase = .pairing
        errorMessage = nil
        pairingError = message
    }

    private func handle(_ error: Error) {
        if let api = error as? APIError, api.isAuthenticationFailure {
            forgetLocally(message: api.errorDescription)
        } else {
            errorMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
