import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case pairing
        case paired
    }

    enum PrescriptionState {
        case idle
        case readinessRequired([String: JSONValue])
        case confirmationRequired([String: JSONValue])
        case issued(IssuedPlanResponse)
        case failed(String)
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
    @Published private(set) var activeWorkout: WorkoutDetail?
    @Published private(set) var progress: ProgressResponse?
    @Published private(set) var progressError: String?
    @Published private(set) var hasLoadedProgress = false
    @Published private(set) var prescriptionState: PrescriptionState = .idle
    @Published private(set) var isSaving = false
    @Published private(set) var isLoadingProgress = false
    @Published private(set) var mutationError: String?

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

    var canWriteReadiness: Bool {
        bootstrap?.capabilities.readinessWrite == true
    }

    var canPrescribe: Bool {
        bootstrap?.capabilities.prescription == true
    }

    var canWriteWorkout: Bool {
        bootstrap?.capabilities.workoutWrite == true
    }

    var canWrite: Bool {
        canWriteReadiness && canPrescribe && canWriteWorkout
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
            if let active = newToday.activeWorkout {
                activeWorkout = active
            } else if activeWorkout?.status != "in_progress" {
                // A start can race a refresh; keep the just-started workout until the next
                // read reports it. Completed/abandoned workouts are cleared.
                activeWorkout = nil
            }
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

    // MARK: Phase 2 mutations

    func saveReadiness(
        values: [String: Double],
        note: String?,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await client.writeReadiness(
                ReadinessWriteRequest(values: values, note: note),
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            await refresh()
            return true
        } catch {
            handleMutation(error)
            return false
        }
    }

    func issuePrescription(
        readinessAck: Bool,
        confirmations: [String: Bool]? = nil,
        idempotencyKey: String
    ) async {
        guard let session else { return }
        isSaving = true
        defer { isSaving = false }
        mutationError = nil
        do {
            let issued = try await client.issuePrescription(
                IssuePrescriptionRequest(
                    readinessAck: readinessAck,
                    confirmations: confirmations
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
            prescriptionState = .issued(issued)
            await refresh()
        } catch let error as APIError {
            if error.isAuthenticationFailure {
                handle(error)
                return
            }
            switch error.code {
            case "readiness_required":
                prescriptionState = .readinessRequired(error.details ?? [:])
            case "confirmation_required":
                prescriptionState = .confirmationRequired(error.details ?? [:])
            default:
                handleMutation(error)
                prescriptionState = .failed(message(for: error))
            }
        } catch {
            handleMutation(error)
            prescriptionState = .failed(message(for: error))
        }
    }

    func clearPrescription() {
        prescriptionState = .idle
        mutationError = nil
    }

    func startWorkout(idempotencyKey: String) async -> Bool {
        guard let session, case .issued(let issued) = prescriptionState else {
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            activeWorkout = try await client.startWorkout(
                issuedPlanId: issued.issuedPlanId,
                session: session,
                idempotencyKey: idempotencyKey
            )
            // Keep the issued state so the preview sheet stays presented and can switch to
            // the active workout. The sheet binding clears it when the sheet is dismissed.
            mutationError = nil
            await refresh()
            return true
        } catch {
            if let api = error as? APIError, api.isAuthenticationFailure {
                handle(error)
                return false
            }
            if let api = error as? APIError,
               ["workout_active", "plan_consumed", "plan_expired", "plan_superseded"]
                .contains(api.code ?? "") {
                prescriptionState = .idle
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func addSet(_ body: AddSetRequest, idempotencyKey: String) async -> Bool {
        guard let session, let workout = activeWorkout else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            activeWorkout = try await client.addSet(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            return true
        } catch {
            handleMutation(error)
            return false
        }
    }

    func rateForm(_ body: FormRatingRequest, idempotencyKey: String) async -> Bool {
        guard let session, let workout = activeWorkout else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            activeWorkout = try await client.rateForm(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            return true
        } catch {
            handleMutation(error)
            return false
        }
    }

    func completeWorkout(
        _ body: CompleteWorkoutRequest,
        idempotencyKey: String
    ) async -> Bool {
        guard let session, let workout = activeWorkout else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            activeWorkout = try await client.completeWorkout(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            await refresh()
            await loadHistory(reset: true)
            return true
        } catch {
            handleMutation(error)
            return false
        }
    }

    func abandonWorkout(idempotencyKey: String) async -> Bool {
        guard let session, let workout = activeWorkout else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            activeWorkout = try await client.abandonWorkout(
                workoutId: workout.workoutId,
                session: session,
                idempotencyKey: idempotencyKey
            )
            mutationError = nil
            await refresh()
            return true
        } catch {
            handleMutation(error)
            return false
        }
    }

    func loadProgress(weeks: Int = 8) async {
        guard let session, !isLoadingProgress else { return }
        isLoadingProgress = true
        defer { isLoadingProgress = false }
        do {
            progress = try await client.progress(weeks: weeks, session: session)
            progressError = nil
            hasLoadedProgress = true
        } catch {
            if let api = error as? APIError, api.isAuthenticationFailure {
                handle(error)
            } else {
                progressError = message(for: error)
            }
        }
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
        activeWorkout = nil
        progress = nil
        progressError = nil
        hasLoadedProgress = false
        prescriptionState = .idle
        isSaving = false
        isLoadingProgress = false
        mutationError = nil
        pairedServerURL = store.serverURL
        phase = .pairing
        errorMessage = nil
        pairingError = message
    }

    private func handleMutation(_ error: Error) {
        if let api = error as? APIError, api.isAuthenticationFailure {
            forgetLocally(message: api.errorDescription)
        } else {
            mutationError = message(for: error)
        }
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
