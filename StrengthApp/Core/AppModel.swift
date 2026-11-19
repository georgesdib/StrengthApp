import Combine
import Foundation
import StrengthCore

struct OfflineRecoveryConflict: Equatable {
    let currentWorkoutID: String
    let recoveredWorkoutID: String
    let pendingOperationCount: Int
}

enum AppTab: Hashable {
    case today
    case history
    case progress
    case explain
    case settings
}

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
        case generating(PlanProgress)
        case issued(IssuedPlanResponse)
        case failed(String)
    }

    enum RecoveryIssue: Equatable {
        case serverActiveWorkout(workoutId: String, sessionType: String?)
        case workoutEndedElsewhere(workoutId: String)
        case prescriptionUnavailable(reason: String)
    }

    struct RefreshOutcome: Equatable {
        let succeeded: Bool
        let message: String?

        static let success = RefreshOutcome(succeeded: true, message: nil)

        static func failure(_ message: String) -> RefreshOutcome {
            RefreshOutcome(succeeded: false, message: message)
        }
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var bootstrap: BootstrapResponse?
    @Published private(set) var today: TodayResponse?
    @Published private(set) var sessions: [HistorySession] = []
    @Published private(set) var historyTotal = 0
    @Published private(set) var isPairing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var healthKitRefreshError: String?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasLoadedHistory = false
    @Published private(set) var device: PairingDevice?
    @Published private(set) var pairedServerURL: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pairingError: String?
    @Published private(set) var activeWorkout: WorkoutDetail? {
        didSet {
            // A different workout starts with no open exercises; the same workout keeps them.
            guard activeWorkout?.workoutId != oldValue?.workoutId else { return }
            activeExercises = []
            persistActiveExercises()
        }
    }
    /// Exercises the lifter started and has not ended. Supersets keep more than one open, and a
    /// set — not a screen — is what starts one.
    @Published private(set) var activeExercises: [ActiveExercise] = []
    @Published var narrativeEnabled: Bool = UserDefaults.standard.bool(
        forKey: "intelligence.narrative.enabled"
    ) {
        didSet { UserDefaults.standard.set(narrativeEnabled, forKey: "intelligence.narrative.enabled") }
    }
    @Published var chatEnabled: Bool = UserDefaults.standard.bool(
        forKey: "intelligence.chat.enabled"
    ) {
        didSet { UserDefaults.standard.set(chatEnabled, forKey: "intelligence.chat.enabled") }
    }
    @Published var chatModelChoice: ChatModelChoice = ChatModelChoice(
        rawValue: UserDefaults.standard.string(forKey: "intelligence.chat.model") ?? ""
    ) ?? .onDevice {
        didSet {
            UserDefaults.standard.set(chatModelChoice.rawValue, forKey: "intelligence.chat.model")
        }
    }
    @Published var chatPlanEnabled: Bool = UserDefaults.standard.bool(
        forKey: "intelligence.chat.plan"
    ) {
        didSet { UserDefaults.standard.set(chatPlanEnabled, forKey: "intelligence.chat.plan") }
    }
    /// Separate consent for health measurements (cardio minutes, time-in-zone, VO2max) leaving the
    /// device. Plan data has its own toggle; health is a different class (DEC-LONGEVITY-02).
    @Published var chatHealthEnabled: Bool = UserDefaults.standard.bool(
        forKey: "intelligence.chat.health"
    ) {
        didSet { UserDefaults.standard.set(chatHealthEnabled, forKey: "intelligence.chat.health") }
    }
    /// The deterministic longevity facts behind the Today section; nil until loaded.
    @Published private(set) var longevity: LongevitySummary?
    /// Why the facts are missing. Nil once they load; never silently empty.
    @Published private(set) var longevityError: String?
    @Published private(set) var deepSeekKeyPresent = false
    private let deepSeekKeyStore: any DeepSeekKeyStoring = KeychainDeepSeekKeyStore()
    @Published var narrativeDetail: NarrativeDetail = NarrativeDetail(
        rawValue: UserDefaults.standard.string(forKey: "intelligence.narrative.detail") ?? ""
    ) ?? .standard {
        didSet { UserDefaults.standard.set(narrativeDetail.rawValue, forKey: "intelligence.narrative.detail") }
    }
    @Published private(set) var offlineCapture: OfflineCapture?
    @Published private(set) var offlineRecoveryError: OfflineCaptureStoreError?
    @Published private(set) var offlinePersistenceError: String?
    @Published private(set) var offlineTelemetryError: String?
    @Published private(set) var offlineRecoveryConflict: OfflineRecoveryConflict?
    @Published private(set) var isOffline = false
    @Published private(set) var isSyncingOffline = false
    @Published private(set) var offlineSyncError: String?
    @Published private(set) var exerciseCatalogue: [ExerciseOption] = []
    @Published private(set) var isLoadingExerciseCatalogue = false
    @Published private(set) var exerciseCatalogueError: String?
    @Published private(set) var exerciseCatalogueCachedAt: Date?
    @Published private(set) var exerciseDetail: ExerciseDetailResponse?
    @Published private(set) var isLoadingExerciseDetail = false
    @Published private(set) var exerciseDetailError: String?
    @Published private(set) var exerciseHistorySessions: [ExerciseHistorySession] = []
    @Published private(set) var exerciseHistoryIncluded: [ExerciseHistoryIncluded] = []
    @Published private(set) var exerciseHistoryTotal = 0
    @Published private(set) var exerciseHistoryHasMore = false
    @Published private(set) var isLoadingExerciseHistory = false
    @Published private(set) var exerciseHistoryError: String?
    @Published private(set) var progress: ProgressResponse?
    @Published private(set) var progressError: String?
    @Published private(set) var hasLoadedProgress = false
    @Published private(set) var prescriptionState: PrescriptionState = .idle
    /// Settings the owner chose for the current request, kept for retry after a lost response.
    @Published private(set) var planSettings = PlanSettings()
    private var planPollTask: Task<Void, Never>?
    private var planPollFailures = 0
    private static let maxPlanPollFailures = 10
    @Published private(set) var isSaving = false
    /// One rest interval for the whole app; the tab shell renders it on every screen.
    let restTimer = RestTimerModel()
    @Published var selectedTab: AppTab = .today
    @Published var showReadinessSheet = false
    /// Daily reminder. The time is stored as hour and minute so a DST change follows the device clock.
    @Published var reminderEnabled: Bool = UserDefaults.standard.bool(forKey: "nudge.enabled") {
        didSet {
            UserDefaults.standard.set(reminderEnabled, forKey: "nudge.enabled")
            Task { @MainActor in
                if reminderEnabled { _ = await self.nudges.requestAuthorization() }
                await self.refreshNudges()
            }
        }
    }
    @Published var reminderHour: Int = UserDefaults.standard.object(
        forKey: "nudge.hour"
    ) as? Int ?? 18 {
        didSet {
            UserDefaults.standard.set(reminderHour, forKey: "nudge.hour")
            scheduleNudgeRefresh()
        }
    }
    @Published var reminderMinute: Int = UserDefaults.standard.object(
        forKey: "nudge.minute"
    ) as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(reminderMinute, forKey: "nudge.minute")
            scheduleNudgeRefresh()
        }
    }
    @Published private(set) var notificationsAuthorized = true
    @Published private(set) var lastReminderOutcome: String?
    @Published var todaySummaryEnabled: Bool = (UserDefaults.standard.object(
        forKey: "todaySummary.enabled"
    ) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(todaySummaryEnabled, forKey: "todaySummary.enabled")
        }
    }
    @Published private(set) var isLoadingProgress = false
    @Published private(set) var mutationError: String?
    @Published private(set) var mutationFailureAmbiguous = false
    @Published private(set) var pendingMutations: [PendingMutation] = []
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var recoveryIssue: RecoveryIssue?
    @Published private(set) var isRecovering = false
    @Published private(set) var healthKitEnabled: Bool
    @Published private(set) var healthKitState: HealthKitReadinessState
    @Published private(set) var isImportingHealthKit = false
    @Published private(set) var isSyncingActivity = false
    @Published private(set) var activitySyncMessage: String?
    /// True when the last activity sync left rejected records on the server. The Cardio screen uses
    /// this to distinguish a partial ingestion from an ordinary success message.
    @Published private(set) var activitySyncNeedsAttention = false
    /// Keys the backend rejected and the app now skips. They need investigation; dismissing the
    /// warning does not make the missing data reappear.
    @Published private(set) var quarantinedActivityWorkoutKeys: [String] = []
    @Published private(set) var quarantinedActivitySampleKeys: [String] = []
    @Published private(set) var healthKitSelection: HealthKitReadinessSelection?

    @Published var serverURLText: String
    @Published var homeServerText: String
    @Published var awayServerText: String
    @Published var preferHome: Bool
    @Published private(set) var activeServerRoute: ServerRoute?
    @Published private(set) var homeServerProbe: ServerProbeResult?
    /// Kept for routing and existing readers; the reason lives in homeServerProbe.
    var homeServerReachable: Bool? { homeServerProbe.map(\.isReachable) }
    @Published private(set) var isCheckingHomeServer = false
    @Published private(set) var serverSettingsError: String?
    /// An address the app accepted but the system will refuse to load. Saving still succeeds: the
    /// owner may be mid-edit, and a warning must not block an unrelated correction.
    @Published private(set) var serverSettingsWarning: String?
    @Published var pairingCodeText: String = ""
    @Published var pairingLabelText: String

    private static let healthKitDefaultsKey = "healthKitReadinessEnabled"
    private static let activitySyncIssueKey = "healthkit.activity.lastIssue.v1"

    /// Persisted so a partial ingestion is still visible after the app is relaunched; the in-memory
    /// message alone would make the warning easy to miss.
    private struct ActivitySyncIssue: Codable {
        let at: Date
        let workoutsRejected: Int
        let samplesRejected: Int
        let metricsSkipped: Int
        let samplesDeferred: Bool
    }
    private let client: IOSAPIClient
    private let tokens: TokenStoring
    private let store: PairedStore
    let watchPairing: WatchPairingCoordinator
    private let healthKit: any HealthKitReadinessProviding
    private let recovery: RecoveryHRVService
    private let healthKitActivity: any HealthKitActivityProviding
    private let healthKitDefaults: UserDefaults
    private let offlineStore: OfflineCaptureStore
    private let pageSize = 50
    private var session: IOSSession?
    private var historyOffset = 0
    private var workoutRefreshGrace = false
    private var healthKitOperation = OperationKey<HealthKitReadinessRequest>()
    private var healthKitFollowUp = false
    private var networkMonitor: NetworkMonitor?
    private var restDoneCancellable: AnyCancellable?
    private var restActivityCancellable: AnyCancellable?
    private var nudgeTapCancellable: AnyCancellable?
    private var nudgeRefreshTask: Task<Void, Never>?
    private let nudges = NudgeScheduler.shared
    private var offlineRetryTask: Task<Void, Never>?
    private var offlineRetryAttempt = 0
    private let exerciseCatalogueCache: ExerciseCatalogueCache
    private let automation: WorkoutAutomation
    private var exerciseCatalogueLoadedServerURL: String?
    private var exerciseDetailCache: [String: ExerciseDetailResponse] = [:]
    private var exerciseHistoryExerciseId: String?
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshWaiters: [CheckedContinuation<RefreshOutcome, Never>] = []
    private var readinessLockBusy = false
    private var readinessLockWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        client: IOSAPIClient? = nil,
        tokens: TokenStoring? = nil,
        store: PairedStore? = nil,
        healthKit: (any HealthKitReadinessProviding)? = nil,
        healthKitDefaults: UserDefaults = .standard,
        offlineStore: OfflineCaptureStore? = nil,
        watchConnectivity: WatchConnectivitySession? = nil,
        exerciseCatalogueCache: ExerciseCatalogueCache? = nil,
        automation: WorkoutAutomation? = nil
    ) {
        let store = store ?? PairedStore()
        store.migrateServerConfigurationIfNeeded()
        let readiness = healthKit ?? HealthKitReadinessService()
        let activity = HealthKitActivityService(defaults: healthKitDefaults)
        let enabled = healthKitDefaults.bool(forKey: Self.healthKitDefaultsKey)
        let captureStore = offlineStore ?? OfflineCaptureStore()
        let resolvedAutomation = automation ?? WorkoutAutomation.shared
        let initialCapture: OfflineCapture?
        let initialRecoveryError: OfflineCaptureStoreError?
        do {
            initialCapture = try captureStore.load()
            initialRecoveryError = nil
        } catch let error as OfflineCaptureStoreError {
            initialCapture = nil
            initialRecoveryError = error
        } catch {
            initialCapture = nil
            initialRecoveryError = .io(error.localizedDescription)
        }
        let apiClient = client ?? IOSAPIClient(journal: MutationJournal())
        self.client = apiClient
        self.tokens = tokens ?? KeychainTokenStore()
        self.store = store
        self.watchPairing = WatchPairingCoordinator(
            client: apiClient,
            store: store,
            connectivity: watchConnectivity
        )
        self.healthKit = readiness
        self.recovery = RecoveryHRVService(
            healthKit: readiness, client: apiClient, defaults: healthKitDefaults
        )
        self.healthKitActivity = activity
        self.healthKitDefaults = healthKitDefaults
        self.offlineStore = captureStore
        self.exerciseCatalogueCache = exerciseCatalogueCache ?? ExerciseCatalogueCache()
        self.automation = resolvedAutomation
        self.deepSeekKeyPresent = ((try? self.deepSeekKeyStore.load()) ?? nil)?.isEmpty == false
        self.healthKitEnabled = enabled
        self.healthKitState = enabled
            ? (readiness.isAvailable ? .enabled : .unavailable)
            : .featureDisabled
        self.serverURLText = store.serverURL ?? AppConfig.defaultServerURL
        self.homeServerText = store.homeServerURL ?? ""
        self.awayServerText = store.awayServerURL ?? ""
        self.preferHome = store.preferHome
        self.pairingLabelText = store.device?.label ?? "iPhone"
        self.offlineCapture = initialCapture
        self.offlineRecoveryError = initialRecoveryError
        self.activeWorkout = initialCapture?.activeWorkout
        restTimer.onFinish = { [weak self] result in
            self?.recordRestResult(result)
        }
        restTimer.onExtend = { [weak self] seconds in
            self?.recordRestExtension(seconds)
        }
        restActivityCancellable = NotificationCenter.default
            .publisher(for: .restActivityChangedExternally)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.drainRestActivityChanges()
                }
            }
        restDoneCancellable = NotificationCenter.default
            .publisher(for: .restNotificationDone)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleRestNotificationDone()
                }
            }
        nudgeTapCancellable = NotificationCenter.default
            .publisher(for: NudgeRouter.tapped)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handlePendingNudgeTap()
                }
            }
        quarantinedActivityWorkoutKeys = activity.quarantinedWorkoutKeys
        quarantinedActivitySampleKeys = activity.quarantinedSampleKeys
        if let issue = Self.loadActivitySyncIssue(from: healthKitDefaults) {
            activitySyncMessage = Self.activityIssueMessage(
                issue,
                quarantinedWorkouts: quarantinedActivityWorkoutKeys,
                quarantinedSamples: quarantinedActivitySampleKeys
            )
            activitySyncNeedsAttention = true
        } else if !quarantinedActivityWorkoutKeys.isEmpty
                    || !quarantinedActivitySampleKeys.isEmpty {
            activitySyncMessage = Self.activityQuarantineMessage(
                quarantinedWorkouts: quarantinedActivityWorkoutKeys,
                quarantinedSamples: quarantinedActivitySampleKeys
            )
            activitySyncNeedsAttention = true
        }
        restoreExerciseSession()
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

    var pendingOfflineOperations: [OfflineOperation] {
        offlineCapture?.operations ?? []
    }

    var pendingOfflineCount: Int { pendingOfflineOperations.count }

    var hasPendingOfflineCapture: Bool { !pendingOfflineOperations.isEmpty }

    var offlineRecoveryUnavailable: Bool { offlineRecoveryError != nil }

    var offlineRecoveryMessage: String? { offlineRecoveryError?.errorDescription }

    var offlineFinishPending: Bool {
        pendingOfflineOperations.contains {
            $0.kind == .completeWorkout && $0.state == .pending
        }
    }

    var offlineCaptureActive: Bool { isOffline || hasPendingOfflineCapture }

    var canPrescribe: Bool {
        bootstrap?.capabilities.prescription == true
    }

    var canWriteWorkout: Bool {
        bootstrap?.capabilities.workoutWrite == true
    }

    var canWrite: Bool {
        canWriteReadiness && canPrescribe && canWriteWorkout
    }

    /// Incremental HealthKit activity (C2). The history was promoted from an export, so this only
    /// ever carries what happened after the cutoff — the app never backfills.
    var canSyncActivity: Bool {
        healthKitActivity.isAvailable && bootstrap?.capabilities.healthkitActivity == true
    }

    /// Authenticated cardio summary for the overview screen.
    /// Loads the longevity facts on their own, without a model.
    ///
    /// They used to load inside the summary generator's facts closure, which does not run when the
    /// on-device model is unavailable — the card then showed nothing at all.
    func loadLongevity(force: Bool = false) async {
        if !force, longevity != nil { return }
        guard let session else {
            longevityError = "pair with the server to see aerobic activity."
            return
        }
        do {
            let envelope = try await client.longevity(session: session)
            if let summary = LongevitySummary(envelope: envelope) {
                longevity = summary
                longevityError = nil
            } else {
                longevityError = "the server returned no longevity assessment."
            }
        } catch is CancellationError {
            // The view went away mid-request. Cancellation is not a finding; the next appearance
            // asks again rather than displaying "cancelled".
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            longevityError = (error as? LocalizedError)?.errorDescription
                ?? "the longevity assessment could not be loaded."
        }
    }

    func loadCardioActivity(weeks: Int = 12, tiz: Bool = false) async throws -> CardioActivityPayload {
        guard let session else { throw CardioOverviewError.notPaired }
        return try await client.cardioActivity(session: session, weeks: weeks, includeTimeInZone: tiz)
    }

    enum CardioOverviewError: LocalizedError {
        case notPaired
        var errorDescription: String? { "Pair with the server to see cardio activity." }
    }

    func syncHealthKitActivity() async {
        guard !isSyncingActivity else { return }
        guard let session else {
            activitySyncMessage = "Pair with the server before syncing activity."
            return
        }
        isSyncingActivity = true
        activitySyncMessage = nil
        defer { isSyncingActivity = false }
        do {
            try await healthKitActivity.requestAuthorization()
            let now = Date()
            let report = try await HealthKitActivitySync(
                client: client, activity: healthKitActivity
            ).run(session: session, at: now)
            refreshActivityQuarantine()
            if report.isPartial {
                let issue = ActivitySyncIssue(
                    at: now,
                    workoutsRejected: report.workoutsRejected,
                    samplesRejected: report.samplesRejected,
                    metricsSkipped: report.metricsSkipped,
                    samplesDeferred: report.samplesDeferred
                )
                Self.saveActivitySyncIssue(issue, to: healthKitDefaults)
                activitySyncNeedsAttention = true
                activitySyncMessage = Self.activityIssueMessage(
                    issue,
                    quarantinedWorkouts: quarantinedActivityWorkoutKeys,
                    quarantinedSamples: quarantinedActivitySampleKeys
                )
            } else if !quarantinedActivityWorkoutKeys.isEmpty
                        || !quarantinedActivitySampleKeys.isEmpty {
                // This sync was clean, but earlier rejected records are still skipped. Keep the
                // warning rather than implying the history is complete.
                Self.clearActivitySyncIssue(from: healthKitDefaults)
                activitySyncNeedsAttention = true
                activitySyncMessage = Self.activityQuarantineMessage(
                    quarantinedWorkouts: quarantinedActivityWorkoutKeys,
                    quarantinedSamples: quarantinedActivitySampleKeys
                )
            } else {
                Self.clearActivitySyncIssue(from: healthKitDefaults)
                activitySyncNeedsAttention = false
                activitySyncMessage = Self.activitySuccessMessage(report, now: now)
            }
        } catch {
            // A transport or validation failure is eligible for retry: the coordinator advances
            // each cursor only after its own half was accepted, so a confirmed half is kept.
            refreshActivityQuarantine()
            activitySyncNeedsAttention = true
            activitySyncMessage = "Sync stopped before all data was confirmed: "
                + "\(error.localizedDescription) The next sync retries from the last saved cursor."
        }
    }

    /// Stop showing a quarantine warning after the owner has investigated it. The rejected records
    /// stay on the server untouched; this only clears the local warning and the skip list, so a
    /// later sync inside the overlap window can retry them.
    func dismissActivityQuarantine() {
        healthKitActivity.clearQuarantine()
        refreshActivityQuarantine()
        Self.clearActivitySyncIssue(from: healthKitDefaults)
        activitySyncNeedsAttention = false
        activitySyncMessage = nil
    }

    private func refreshActivityQuarantine() {
        quarantinedActivityWorkoutKeys = healthKitActivity.quarantinedWorkoutKeys
        quarantinedActivitySampleKeys = healthKitActivity.quarantinedSampleKeys
    }

    private static func activitySuccessMessage(
        _ report: HealthKitActivitySyncReport,
        now: Date
    ) -> String {
        if report.isEmpty {
            return "Nothing new since \(shortDate(now))."
        }
        let created = report.workoutsCreated + report.samplesCreated + report.metricsWritten
        if created == 0 {
            return "Everything in this sync window was already on the server."
        }
        var parts: [String] = []
        if report.workoutsCreated > 0 {
            parts.append("\(report.workoutsCreated) workout(s)")
        }
        if report.samplesCreated > 0 {
            parts.append("\(report.samplesCreated) heart-rate sample(s)")
        }
        if report.metricsWritten > 0 {
            parts.append("\(report.metricsWritten) VO₂max measurement(s)")
        }
        return "Synced " + parts.joined(separator: ", ") + "."
    }

    private static func activityIssueMessage(
        _ issue: ActivitySyncIssue,
        quarantinedWorkouts: [String],
        quarantinedSamples: [String]
    ) -> String {
        var counts: [String] = []
        if issue.workoutsRejected > 0 {
            counts.append("\(issue.workoutsRejected) workout(s)")
        }
        if issue.samplesRejected > 0 {
            counts.append("\(issue.samplesRejected) heart-rate sample(s)")
        }
        if issue.metricsSkipped > 0 {
            counts.append("\(issue.metricsSkipped) VO₂max measurement(s)")
        }
        let rejected = counts.isEmpty ? "Some records" : counts.joined(separator: ", ")
        var message = "Partial sync on \(shortDate(issue.at)): \(rejected) rejected or skipped "
            + "by the server."
        if issue.samplesDeferred {
            message += " The workout cursor was held and samples were deferred."
        }
        let hasQuarantine = !quarantinedWorkouts.isEmpty || !quarantinedSamples.isEmpty
        if hasQuarantine {
            message += " " + quarantineSummary(
                quarantinedWorkouts: quarantinedWorkouts,
                quarantinedSamples: quarantinedSamples
            )
            message += " The cursor advanced past the quarantined keys."
        } else if issue.metricsSkipped > 0 {
            message += " Skipped metrics are re-checked on every sync."
        } else if !issue.samplesDeferred {
            message += " The affected cursor was not advanced."
        }
        message += " Investigate before retrying."
        return message
    }

    private static func activityQuarantineMessage(
        quarantinedWorkouts: [String],
        quarantinedSamples: [String]
    ) -> String {
        quarantineSummary(
            quarantinedWorkouts: quarantinedWorkouts,
            quarantinedSamples: quarantinedSamples
        ) + " They are skipped on future syncs; dismiss this warning only after investigating."
    }

    private static func quarantineSummary(
        quarantinedWorkouts: [String],
        quarantinedSamples: [String]
    ) -> String {
        var parts: [String] = []
        if !quarantinedWorkouts.isEmpty {
            parts.append(
                "\(quarantinedWorkouts.count) workout(s) quarantined: "
                    + keyList(quarantinedWorkouts)
            )
        }
        if !quarantinedSamples.isEmpty {
            parts.append(
                "\(quarantinedSamples.count) heart-rate sample(s) quarantined: "
                    + keyList(quarantinedSamples)
            )
        }
        return parts.joined(separator: ". ") + "."
    }

    private static func keyList(_ keys: [String]) -> String {
        let shown = keys.prefix(3).joined(separator: ", ")
        guard keys.count > 3 else { return shown }
        return shown + ", +" + String(keys.count - 3) + " more"
    }

    private static func loadActivitySyncIssue(from defaults: UserDefaults) -> ActivitySyncIssue? {
        guard let data = defaults.data(forKey: activitySyncIssueKey) else { return nil }
        return try? JSONDecoder().decode(ActivitySyncIssue.self, from: data)
    }

    private static func saveActivitySyncIssue(
        _ issue: ActivitySyncIssue,
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(issue) else { return }
        defaults.set(data, forKey: activitySyncIssueKey)
    }

    private static func clearActivitySyncIssue(from defaults: UserDefaults) {
        defaults.removeObject(forKey: activitySyncIssueKey)
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var canUseHealthKit: Bool {
        healthKit.isAvailable && bootstrap?.capabilities.healthkitReadiness == true
    }

    // MARK: Lifecycle

    func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }
        networkMonitor = NetworkMonitor { [weak self] in
            Task { @MainActor in
                await self?.appBecameActive()
            }
        }
    }

    func onLaunch() async {
        guard phase == .loading else { return }
        homeServerText = store.homeServerURL ?? ""
        awayServerText = store.awayServerURL ?? ""
        preferHome = store.preferHome
        updateServerAddressWarning()
        let configuration = store.serverConfiguration
        let token = tokens.load()
        let pairedDevice = store.device
        let selection = await chooseServerSelection(configuration, token: token)
        let savedURL = selection?.url ?? store.serverURL
        guard let savedURL,
              let baseURL = try? IOSAPIClient.validatedBaseURL(savedURL) else {
            phase = .pairing
            return
        }
        serverURLText = baseURL.absoluteString
        activeServerRoute = selection?.route ?? .home
        guard let token, let pairedDevice else {
            phase = .pairing
            return
        }
        session = IOSSession(
            baseURL: baseURL,
            token: token,
            deviceID: pairedDevice.deviceID
        )
        device = pairedDevice
        store.serverURL = baseURL.absoluteString
        pairedServerURL = baseURL.absoluteString
        pairingLabelText = pairedDevice.label
        phase = .paired
        if let session {
            watchPairing.start(session: session, homeBaseURL: store.homeServerURL)
        }
        let refreshed = await refresh()
        isOffline = !refreshed.succeeded
        await recoverPendingMutations()
        await syncOfflineCapture()
        if refreshed.succeeded, healthKitEnabled {
            await importHealthKit()
        }
    }

    private func chooseServerSelection(
        _ configuration: ServerConfiguration,
        token: String?
    ) async -> (route: ServerRoute, url: String)? {
        var probe: ServerProbeResult?
        let home = configuration.homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = configuration.awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.preferHome, !home.isEmpty, !away.isEmpty, home != away,
           let token, let homeURL = try? IOSAPIClient.validatedBaseURL(home) {
            isCheckingHomeServer = true
            probe = await client.probeServer(baseURL: homeURL, token: token)
            isCheckingHomeServer = false
        }
        homeServerProbe = probe
        return ServerConfiguration.select(
            homeURL: configuration.homeURL,
            awayURL: configuration.awayURL,
            preferHome: configuration.preferHome,
            homeReachable: probe.map(\.isReachable)
        )
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
            let prior = store.serverConfiguration
            if prior.homeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.homeServerURL = baseURL.absoluteString
            } else if prior.awayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.awayServerURL = baseURL.absoluteString
            } else if activeServerRoute == .away {
                store.awayServerURL = baseURL.absoluteString
            } else {
                store.homeServerURL = baseURL.absoluteString
            }
            homeServerText = store.homeServerURL ?? ""
            awayServerText = store.awayServerURL ?? ""
            preferHome = store.preferHome
            activeServerRoute = ServerConfiguration.select(
                homeURL: store.homeServerURL ?? "",
                awayURL: store.awayServerURL ?? "",
                preferHome: store.preferHome,
                homeReachable: nil
            )?.route ?? .home
            store.serverURL = baseURL.absoluteString
            store.device = paired
            device = paired
            pairedServerURL = baseURL.absoluteString
            serverURLText = baseURL.absoluteString
            pairingLabelText = response.device.label
            pairingCodeText = ""
            session = IOSSession(
                baseURL: baseURL,
                token: response.token,
                deviceID: response.device.deviceId
            )
            phase = .paired
            store.clearWatchLink()
            watchPairing.reset()
            if let session {
                watchPairing.start(session: session, homeBaseURL: store.homeServerURL)
            }
            let refreshed = await refresh()
            await recoverPendingMutations()
            if refreshed.succeeded, healthKitEnabled {
                await importHealthKit()
            }
        } catch {
            pairingError = message(for: error)
        }
    }

    var serverSelectionSummary: String {
        switch activeServerRoute {
        case .home:
            return "Using Home Server"
        case .away:
            return "Using Away Server"
        case nil:
            return "No server selected"
        }
    }

    var homeServerStatus: String {
        if !preferHome {
            return "Prefer Home Server is off; Away Server is used when configured."
        }
        if isCheckingHomeServer {
            return "Checking whether Home Server is reachable…"
        }
        switch homeServerProbe {
        case .reachable:
            return "Home Server is reachable."
        case .unauthorized:
            return "Home Server answered but refused this device credential. Re-pair if it persists."
        case .blockedByPolicy:
            return "iOS refuses the Home Server address, so it is not merely unreachable. Use https:// or a local address."
        case .serverError(let status):
            return "Home Server answered HTTP \(status); Away Server is the fallback."
        case .unreachable:
            return "Home Server is unreachable; Away Server is the fallback."
        case nil:
            return "Home Server is preferred; reachability is checked on launch, foreground and network changes."
        }
    }

    /// Re-check whatever is stored, not just what was typed: an address saved before this check
    /// existed (or on another device) is exactly the case that failed without a warning.
    private func updateServerAddressWarning() {
        serverSettingsWarning = Self.cleartextWarning(
            home: store.homeServerURL ?? "",
            away: store.awayServerURL ?? ""
        )
    }

    /// Addresses that can be stored but not loaded, named so the owner knows which field to fix.
    private static func cleartextWarning(home: String, away: String) -> String? {
        var blocked: [String] = []
        if !home.isEmpty, ServerAddressPolicy.cleartextIsBlocked(home) {
            blocked.append("Home Server")
        }
        if !away.isEmpty, ServerAddressPolicy.cleartextIsBlocked(away) {
            blocked.append("Away Server")
        }
        guard !blocked.isEmpty else { return nil }
        let subject = blocked.joined(separator: " and ")
        return "\(subject) uses http:// with an address iOS refuses. Use https://, or a "
            + "private-network address (192.168.x.x, 10.x.x.x), a .local name or a single-word "
            + "host name. A tailnet or VPN address needs https://."
    }

    func saveServerSettings() async -> Bool {
        serverSettingsError = nil
        var home = homeServerText.trimmingCharacters(in: .whitespacesAndNewlines)
        var away = awayServerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty || !away.isEmpty else {
            serverSettingsError = "Enter at least a Home Server or an Away Server."
            return false
        }
        if !home.isEmpty {
            do { home = try IOSAPIClient.validatedBaseURL(home).absoluteString } catch {
                serverSettingsError = message(for: error)
                return false
            }
        }
        if !away.isEmpty {
            do { away = try IOSAPIClient.validatedBaseURL(away).absoluteString } catch {
                serverSettingsError = message(for: error)
                return false
            }
        }
        let configuration = ServerConfiguration(
            homeURL: home, awayURL: away, preferHome: preferHome
        )
        let selected: (route: ServerRoute, url: String)?
        if phase == .paired, let token = tokens.load() {
            selected = await chooseServerSelection(configuration, token: token)
        } else {
            homeServerProbe = nil
            isCheckingHomeServer = false
            selected = ServerConfiguration.select(
                homeURL: home, awayURL: away, preferHome: preferHome,
                homeReachable: nil
            )
        }
        guard let selected else {
            serverSettingsError = "Configure at least one valid server address."
            return false
        }
        if phase == .paired, let currentSession = session,
           currentSession.baseURL.absoluteString != selected.url,
           hasPendingOfflineCapture || !pendingMutations.isEmpty {
            serverSettingsError = "Sync or discard pending offline work before switching server addresses."
            return false
        }
        store.homeServerURL = home
        store.awayServerURL = away
        store.preferHome = preferHome
        store.bumpWatchConfigVersion()
        homeServerText = home
        awayServerText = away
        updateServerAddressWarning()
        if phase == .pairing {
            serverURLText = selected.url
            activeServerRoute = selected.route
            return true
        }
        await recheckServerSelection(forceRefresh: true)
        await watchPairing.configurationChanged(homeBaseURL: store.homeServerURL)
        return serverSettingsError == nil
    }

    func recheckServerSelection(forceRefresh: Bool = false) async {
        guard phase == .paired else { return }
        let configuration = store.serverConfiguration
        guard let token = tokens.load() else { return }
        guard let selected = await chooseServerSelection(configuration, token: token),
              let baseURL = try? IOSAPIClient.validatedBaseURL(selected.url) else {
            serverSettingsError = "Configure at least one valid server address."
            return
        }
        guard let currentSession = session,
              let pairedDevice = store.device else { return }
        let changed = currentSession.baseURL.absoluteString != baseURL.absoluteString
        if changed, hasPendingOfflineCapture || !pendingMutations.isEmpty {
            serverSettingsError = "Sync or discard pending offline work before switching server addresses."
            return
        }
        serverSettingsError = nil
        updateServerAddressWarning()
        activeServerRoute = selected.route
        if changed {
            session = IOSSession(
                baseURL: baseURL,
                token: token,
                deviceID: pairedDevice.deviceID
            )
            store.serverURL = baseURL.absoluteString
            serverURLText = baseURL.absoluteString
            pairedServerURL = baseURL.absoluteString
            if let session {
                watchPairing.updateSession(session, homeBaseURL: store.homeServerURL)
            }
        }
        if changed || forceRefresh {
            let outcome = await refresh()
            isOffline = !outcome.succeeded
        }
    }

    func appBecameActive() async {
        drainRestActivityChanges()
        await recheckServerSelection()
        await syncOfflineCapture()
        if phase == .paired, let session {
            await watchPairing.foreground(session: session, homeBaseURL: store.homeServerURL)
        }
        handlePendingNudgeTap()
        scheduleNudgeRefresh()
    }

    // MARK: - Daily reminder

    var reminderTime: Date {
        get {
            var components = DateComponents()
            components.hour = reminderHour
            components.minute = reminderMinute
            return Calendar.current.date(from: components) ?? Date()
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            if let hour = components.hour { reminderHour = hour }
            if let minute = components.minute { reminderMinute = minute }
        }
    }

    func handlePendingNudgeTap() {
        guard NudgeRouter.shared.consume() else { return }
        handleNudgeTap()
    }

    /// A tap lands on Today, and opens readiness when that is the thing actually missing.
    func handleNudgeTap() {
        guard phase == .paired else { return }
        selectedTab = .today
        if canWriteReadiness, today?.readiness?.isLogged != true {
            showReadinessSheet = true
        }
    }

    func refreshNudges() async {
        notificationsAuthorized = await nudges.isAuthorized
        guard phase == .paired else {
            await nudges.clear()
            return
        }
        await nudges.refresh(
            enabled: reminderEnabled,
            hour: reminderHour,
            minute: reminderMinute,
            facts: reminderEnabled ? currentNudgeFacts() : nil
        )
        lastReminderOutcome = nudges.lastOutcomeSummary
    }

    private func scheduleNudgeRefresh() {
        nudgeRefreshTask?.cancel()
        nudgeRefreshTask = Task { @MainActor [weak self] in
            // Collapse the burst of refreshes a foreground or a mutation produces.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.refreshNudges()
        }
    }

    private func currentNudgeFacts() -> NudgeFacts {
        let readiness: NudgeFacts.Readiness
        if today?.readiness?.isLogged == true {
            readiness = .logged(score: today?.readinessScore?.score)
        } else if today?.readiness?.hasEntry == true {
            // The athlete answered some fields but the server could not form a score. The
            // reminder must ask for the rest, not claim readiness is already logged.
            readiness = .partial
        } else {
            readiness = .missing
        }
        var planned: NudgeFacts.PlannedSession?
        if case .issued(let issued) = prescriptionState {
            let items = issued.plan.items
            let focus = items.first { ($0.loadKg ?? 0) > 0 } ?? items.first
            planned = NudgeFacts.PlannedSession(
                label: issued.plan.sessionLabel ?? Self.sessionLabel(issued.sessionType),
                exerciseCount: items.count,
                focusName: focus.flatMap { item in
                    exerciseCatalogue.first { $0.id == item.exerciseId }?.display
                },
                focusSets: focus?.sets,
                focusReps: focus?.repsLabel,
                focusLoadKg: focus?.loadKg
            )
        }
        return NudgeFacts(
            readiness: readiness,
            planned: planned,
            sessionInProgress: activeWorkout != nil
        )
    }

    private static func sessionLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Today summary

    func makeTodaySummaryModel() -> TodaySummaryModel {
        let facts: @MainActor () async -> TodaySummaryFacts = { [weak self] in
            await self?.todaySummaryFacts()
                ?? TodaySummaryFacts(date: Self.isoDate(), readinessLogged: false)
        }
        // The configured chat model is the configured agent. There is no silent fallback: a
        // DeepSeek selection with no key shows the reason instead of using the on-device model.
        if chatModelChoice == .deepSeek {
            let key = (try? deepSeekKeyStore.load()) ?? nil
            return TodaySummaryModel(
                generator: DeepSeekTodaySummaryGenerator(
                    api: DeepSeekClient(apiKey: key),
                    keyPresent: key?.isEmpty == false
                ),
                modelLabel: "DeepSeek",
                sendsFactsOffDevice: true,
                facts: facts
            )
        }
        return TodaySummaryModel(
            generator: FoundationTodaySummaryGenerator(),
            modelLabel: "On this iPhone",
            sendsFactsOffDevice: false,
            facts: facts
        )
    }

    func todaySummaryFacts() async -> TodaySummaryFacts {
        // The chat plan toggle is the athlete's consent for plan and prescription data leaving the
        // device. With DeepSeek selected and that toggle off, the summary is written without it.
        let includePlan = chatModelChoice == .onDevice || chatPlanEnabled
        let planned = includePlan ? currentNudgeFacts().planned : nil
        var overview: String?
        var longevityFacts: String?
        await loadLongevity()
        if let session {
            let toolbox = ChatToolbox(client: client, session: session)
            overview = try? await toolbox.trainingOverview(asOf: nil, windowWeeks: 4)
        }
        // The numbers come from the athlete's own server; the consent governs only what is handed
        // to an off-device model.
        if let longevity, chatModelChoice == .onDevice || chatHealthEnabled {
            longevityFacts = longevity.detail
        }
        return TodaySummaryFacts(
            date: today?.date ?? Self.isoDate(),
            readinessLogged: today?.readiness?.isLogged ?? false,
            readinessPartial: today?.readiness?.hasEntry == true
                && today?.readiness?.isLogged != true,
            readinessScore: today?.readinessScore?.score,
            sessionLabel: planned?.label,
            exerciseCount: planned?.exerciseCount,
            leadLift: planned?.focusName,
            leadLoadKg: planned?.focusLoadKg,
            overviewFacts: overview,
            longevity: longevityFacts
        )
    }

    /// The day, the readiness answer, the issued plan and the model choice. A change in any of them
    /// is a different summary, so the card reloads; nothing else does.
    var todaySummaryFingerprint: String {
        let score = today?.readinessScore?.score.map { String($0) } ?? "-"
        let planId: String
        if case .issued(let issued) = prescriptionState {
            planId = issued.issuedPlanId
        } else {
            planId = "-"
        }
        return [
            today?.date ?? "",
            String(today?.readiness?.hasEntry ?? false),
            String(today?.readiness?.isLogged ?? false),
            score,
            planId,
            chatModelChoice.rawValue,
            String(chatHealthEnabled),
            longevity?.headline ?? "-",
        ].joined(separator: "|")
    }

    private static func isoDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: Reads

    /// Coalescing authoritative refresh. A request arriving while another refresh is in
    /// flight is never dropped: it forces one more GET after the current one and every caller
    /// receives the final outcome.
    @discardableResult
    func refresh() async -> RefreshOutcome {
        guard session != nil else {
            return .failure("Pair this device before refreshing.")
        }
        refreshPending = true
        if !refreshInFlight {
            refreshInFlight = true
            isRefreshing = true
            Task { await self.runRefreshLoop() }
        }
        return await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
        }
    }

    private func runRefreshLoop() async {
        var last = RefreshOutcome.failure("Refresh did not complete.")
        while refreshPending {
            refreshPending = false
            last = await performRefresh()
        }
        refreshInFlight = false
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.resume(returning: last)
        }
    }

    private func performRefresh() async -> RefreshOutcome {
        await acquireReadinessLock()
        defer { releaseReadinessLock() }
        guard let session else {
            return .failure("Pair this device before refreshing.")
        }
        do {
            async let bootstrapTask = client.bootstrap(session: session)
            async let todayTask = client.today(session: session)
            let (newBootstrap, newToday) = try await (bootstrapTask, todayTask)
            bootstrap = newBootstrap
            today = newToday
            // R7: the plan area is rendered from the authoritative read, never from a cached
            // Today payload (contract section 6). An active workout wins over a plan preview.
            let planStateResponse = try? await client.planState(session: session)
            if let planStateResponse {
                if newToday.activeWorkout == nil {
                    applyPlanState(planStateResponse)
                    resumePlanPollingIfNeeded()
                } else {
                    // A workout is running, so the preview sheet is showing the workout view.
                    // Starting consumes the plan, which makes plans/current report none; clearing
                    // the state here would dismiss the sheet mid-session. The workout owns the
                    // screen until it ends.
                    stopPlanPolling()
                }
            }
            let previousActive = activeWorkout
            var reconciled = previousActive
            if hasPendingOfflineCapture {
                // Pending offline work owns the local active-workout view. A completed finish
                // leaves this nil while failed/conflict operations remain; do not resurrect a
                // server workout for that state.
                reconciled = offlineCapture?.activeWorkout
                workoutRefreshGrace = false
            } else if let serverActive = newToday.activeWorkout {
                if previousActive?.workoutId != serverActive.workoutId {
                    recoveryIssue = .serverActiveWorkout(
                        workoutId: serverActive.workoutId,
                        sessionType: serverActive.sessionType
                    )
                }
                reconciled = serverActive
                workoutRefreshGrace = false
            } else if let previousActive, previousActive.status == "in_progress" {
                if workoutRefreshGrace {
                    // A mutation just returned an in-progress workout. Keep it for this read;
                    // the next refresh can still reconcile an externally finished workout.
                    workoutRefreshGrace = false
                    reconciled = previousActive
                } else {
                    // The server no longer has the workout this session was showing. Do not
                    // silently keep stale local state; surface it for reconciliation.
                    reconciled = nil
                    recoveryIssue = .workoutEndedElsewhere(
                        workoutId: previousActive.workoutId
                    )
                }
            } else {
                reconciled = nil
                workoutRefreshGrace = false
            }
            _ = apply(.activeWorkoutChanged(reconciled))
            isOffline = false
            scheduleNudgeRefresh()
            if !healthKitEnabled {
                healthKitState = .featureDisabled
            } else if !canUseHealthKit {
                healthKitState = .unavailable
            } else if healthKitState == .featureDisabled || healthKitState == .unavailable {
                healthKitState = .enabled
            }
            healthKitRefreshError = nil
            errorMessage = nil
            return .success
        } catch {
            isOffline = true
            if activeWorkout == nil, let cached = offlineCapture?.activeWorkout {
                _ = apply(.activeWorkoutChanged(cached))
            }
            handle(error)
            return .failure(message(for: error))
        }
    }

    private func persistActiveWorkout() {
        guard offlineRecoveryError == nil, offlineRecoveryConflict == nil else { return }
        guard activeWorkout != nil
                || offlineCapture?.activeWorkout != nil
                || !(offlineCapture?.operations.isEmpty ?? true) else {
            return
        }
        do {
            offlineCapture = try offlineStore.setActiveWorkout(activeWorkout)
            offlinePersistenceError = nil
        } catch let error as OfflineCaptureStoreError {
            offlinePersistenceError = error.errorDescription
        } catch {
            offlinePersistenceError = OfflineCaptureStoreError.io(
                error.localizedDescription
            ).errorDescription
        }
    }

    /// Retry a failed initial recovery read. A successful read adopts the capture, but never
    /// replaces an active workout that is already authoritative in memory.
    @discardableResult
    func retryOfflineRecovery() -> Bool {
        do {
            let recovered = try offlineStore.load()
            offlineCapture = recovered
            offlineRecoveryError = nil
            if activeWorkout == nil {
                offlineRecoveryConflict = nil
                activeWorkout = recovered.activeWorkout
                return true
            }
            if let currentID = activeWorkout?.workoutId,
               let recoveredID = recovered.activeWorkout?.workoutId
                    ?? recovered.operations.first?.workoutId,
               currentID != recoveredID,
               !recovered.operations.isEmpty {
                offlineRecoveryConflict = OfflineRecoveryConflict(
                    currentWorkoutID: currentID,
                    recoveredWorkoutID: recoveredID,
                    pendingOperationCount: recovered.operations.count
                )
                return true
            }
            offlineRecoveryConflict = nil
            return true
        } catch let error as OfflineCaptureStoreError {
            offlineRecoveryError = error
            return false
        } catch {
            offlineRecoveryError = .io(error.localizedDescription)
            return false
        }
    }

    /// Resolve the loaded-capture/current-workout mismatch without silently replaying work
    /// against the wrong workout. This discards only the recovered capture and keeps the
    /// server-authoritative workout that is already in memory.
    @discardableResult
    func keepCurrentWorkoutAndDiscardRecoveredWork() async -> Bool {
        guard let current = activeWorkout, offlineRecoveryConflict != nil else {
            return false
        }
        do {
            try offlineStore.clear()
        } catch let error as OfflineCaptureStoreError {
            offlinePersistenceError = error.errorDescription
            return false
        } catch {
            offlinePersistenceError = OfflineCaptureStoreError.io(
                error.localizedDescription
            ).errorDescription
            return false
        }
        do {
            offlineCapture = try offlineStore.load()
            offlineRecoveryConflict = nil
            offlineRecoveryError = nil
            offlineTelemetryError = nil
            activeWorkout = current
            persistActiveWorkout()
            await refresh()
            return offlinePersistenceError == nil
        } catch let error as OfflineCaptureStoreError {
            offlineRecoveryError = error
            return false
        } catch {
            offlineRecoveryError = .io(error.localizedDescription)
            return false
        }
    }

    /// Keep the recovered capture and make its workout the in-memory active workout. The next
    /// refresh still reconciles it with the server's authoritative state.
    @discardableResult
    func useRecoveredWorkoutAfterConflict() -> Bool {
        guard offlineRecoveryConflict != nil,
              let recovered = offlineCapture?.activeWorkout else {
            return false
        }
        activeWorkout = recovered
        offlineRecoveryConflict = nil
        offlineTelemetryError = nil
        return true
    }

    /// Server-confirmed start/complete/abandon may clear the local capture only when recovery is
    /// healthy. An unreadable file must not be overwritten by an automatic completion path.
    private func clearOfflineCaptureAfterServerCompletion() {
        guard offlineRecoveryError == nil, offlineRecoveryConflict == nil else { return }
        do {
            try offlineStore.clear()
        } catch let error as OfflineCaptureStoreError {
            offlinePersistenceError = error.errorDescription
            return
        } catch {
            offlinePersistenceError = OfflineCaptureStoreError.io(
                error.localizedDescription
            ).errorDescription
            return
        }
        do {
            offlineCapture = try offlineStore.load()
            offlinePersistenceError = nil
        } catch let error as OfflineCaptureStoreError {
            offlineRecoveryError = error
        } catch {
            offlineRecoveryError = .io(error.localizedDescription)
        }
    }

    private func acquireReadinessLock() async {
        if !readinessLockBusy {
            readinessLockBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            readinessLockWaiters.append(continuation)
        }
    }

    private func releaseReadinessLock() {
        if readinessLockWaiters.isEmpty {
            readinessLockBusy = false
        } else {
            let next = readinessLockWaiters.removeFirst()
            next.resume()
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

    func historyDetail(sessionID: String) async throws -> HistoryDetail {
        guard let session else { throw APIError.transport("Pair this device first.") }
        do {
            return try await client.historyDetail(sessionID: sessionID, session: session)
        } catch {
            handle(error)
            throw error
        }
    }

    func workoutSummary(workoutId: String) async throws -> WorkoutSummary {
        guard let session else { throw APIError.transport("Pair this device first.") }
        do {
            return try await client.workoutSummary(
                workoutId: workoutId, session: session
            ).summary
        } catch {
            handle(error)
            throw error
        }
    }

    func executionAnalytics(workoutId: String) async throws -> ExecutionAnalyticsResponse {
        guard let session else { throw APIError.transport("Pair this device first.") }
        do {
            return try await client.executionAnalytics(
                workoutId: workoutId, session: session
            )
        } catch {
            handle(error)
            throw error
        }
    }

    /// Persist execution telemetry before the UI acknowledges the action. The existing Phase 4
    /// outbox owns delivery, ordering and retry; this method never waits for the network.
    func recordExecutionEvents(_ events: [ExecutionEvent]) {
        guard offlineRecoveryError == nil, offlineRecoveryConflict == nil else {
            offlineTelemetryError = "Execution timing was not recorded because offline recovery needs attention."
            return
        }
        // A watch-owned session owns its telemetry as well; the phone mirror is read-only.
        guard !isMirroringWatchSession else { return }
        guard !events.isEmpty, let activeWorkout else { return }
        do {
            offlineCapture = try offlineStore.appendExecutionEvents(
                workoutId: activeWorkout.workoutId,
                events: events,
                activeWorkout: activeWorkout
            )
            offlineSyncError = nil
            offlineTelemetryError = nil
            Task { await syncOfflineCapture() }
        } catch {
            offlineSyncError = message(for: error)
        }
    }

    func recordExecutionEvent(_ event: ExecutionEvent) {
        recordExecutionEvents([event])
    }

    // MARK: Active exercises

    private static let activeExerciseKey = "workout.activeExercises"

    /// The first set starts the exercise; a warm-up counts, because RIR 6 classifies the set, it
    /// does not decide whether an exercise is under way.
    func startExercise(planItemIndex: Int?, exerciseId: String, at date: Date = Date()) {
        guard activeWorkout != nil, !isMirroringWatchSession else { return }
        let key = ActiveExercise.key(planItemIndex: planItemIndex, exerciseId: exerciseId)
        guard !activeExercises.contains(where: { $0.key == key }) else { return }
        activeExercises.append(
            ActiveExercise(
                key: key,
                planItemIndex: planItemIndex,
                exerciseId: exerciseId,
                startedAt: date
            )
        )
        persistActiveExercises()
        recordExecutionEvent(ExecutionEvent(
            eventType: .exerciseStarted,
            occurredAt: ServerClock.encodedISO(date),
            planItemIndex: planItemIndex,
            payload: ["exercise_id": .string(exerciseId)]
        ))
    }

    @discardableResult
    func endExercise(planItemIndex: Int?, exerciseId: String, at date: Date = Date()) -> Bool {
        let key = ActiveExercise.key(planItemIndex: planItemIndex, exerciseId: exerciseId)
        guard let position = activeExercises.firstIndex(where: { $0.key == key }) else {
            return false
        }
        let exercise = activeExercises[position]
        // Record before clearing the state: if the telemetry write fails the exercise is still
        // open and can be ended again.
        recordExecutionEvent(ExecutionEvent(
            eventType: .exerciseCompleted,
            occurredAt: ServerClock.encodedISO(date),
            planItemIndex: exercise.planItemIndex,
            payload: ["exercise_id": .string(exercise.exerciseId)]
        ))
        activeExercises.remove(at: position)
        persistActiveExercises()
        closeRest(for: exercise)
        return true
    }

    func isExerciseActive(planItemIndex: Int?, exerciseId: String) -> Bool {
        let key = ActiveExercise.key(planItemIndex: planItemIndex, exerciseId: exerciseId)
        return activeExercises.contains { $0.key == key }
    }

    /// Finishing the workout closes whatever is still open, so a session never ends with an
    /// exercise started and never completed.
    func endAllExercises(at date: Date = Date()) {
        guard !activeExercises.isEmpty else { return }
        for exercise in activeExercises {
            recordExecutionEvent(ExecutionEvent(
                eventType: .exerciseCompleted,
                occurredAt: ServerClock.encodedISO(date),
                planItemIndex: exercise.planItemIndex,
                payload: ["exercise_id": .string(exercise.exerciseId)]
            ))
        }
        activeExercises = []
        persistActiveExercises()
    }

    private func closeRest(for exercise: ActiveExercise) {
        guard restTimer.startedAt != nil else { return }
        let sameExercise = restTimer.exerciseId.map { $0 == exercise.exerciseId } ?? false
        let sameItem = restTimer.planItemIndex.map { $0 == exercise.planItemIndex } ?? false
        guard sameExercise || sameItem else { return }
        _ = restTimer.finish(outcome: "completed")
    }

    private func persistActiveExercises() {
        guard let workoutId = activeWorkout?.workoutId, !activeExercises.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.activeExerciseKey)
            return
        }
        let session = ActiveExerciseSession(workoutId: workoutId, exercises: activeExercises)
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.activeExerciseKey)
        }
    }

    /// A relaunch keeps the open exercises and a rest that outlived the app, so neither the
    /// completion event nor the rest interval is lost.
    private func restoreExerciseSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.activeExerciseKey),
              let saved = try? JSONDecoder().decode(ActiveExerciseSession.self, from: data),
              let workout = activeWorkout,
              saved.workoutId == workout.workoutId else {
            UserDefaults.standard.removeObject(forKey: Self.activeExerciseKey)
            activeExercises = []
            _ = restTimer.restore(workoutId: nil)
            return
        }
        activeExercises = saved.exercises
        if let result = restTimer.restore(workoutId: workout.workoutId) {
            recordRestResult(result)
        }
    }

    // MARK: Rest timer

    /// Starts the single app-level rest interval and records its telemetry in one place, so a
    /// rest that finishes on Today is indistinguishable from one that finishes in the workout.
    func startRest(
        seconds: Int,
        planItemIndex: Int?,
        exerciseId: String?,
        startedAt: Date? = nil
    ) {
        guard seconds > 0 else { return }
        restTimer.start(
            seconds: seconds,
            planItemIndex: planItemIndex,
            exerciseId: exerciseId,
            startedAt: startedAt,
            workoutId: activeWorkout?.workoutId
        )
        recordExecutionEvent(ExecutionEvent(
            eventType: .restStarted,
            planItemIndex: planItemIndex,
            payload: [
                "prescribed_rest_s": .number(Double(seconds)),
            ]
        ))
    }

    func interruptRest() {
        _ = restTimer.finish(
            outcome: "interrupted",
            reason: "interrupted by next set"
        )
    }

    private func recordRestResult(_ result: RestTimerResult) {
        var payload: [String: JSONValue] = [
            "prescribed_rest_s": .number(Double(result.prescribedSeconds)),
            "actual_rest_s": .number(Double(result.actualSeconds)),
            "outcome": .string(result.outcome),
        ]
        if let reason = result.reason {
            payload["reason"] = .string(reason)
        }
        recordExecutionEvent(ExecutionEvent(
            eventType: result.outcome == "completed" ? .restCompleted : .restSkipped,
            occurredAt: restISO(result.endedAt),
            planItemIndex: result.planItemIndex,
            payload: payload
        ))
    }

    private func recordRestExtension(_ seconds: Int) {
        recordExecutionEvent(ExecutionEvent(
            eventType: .restExtended,
            planItemIndex: restTimer.planItemIndex,
            payload: ["added_s": .number(Double(seconds))]
        ))
    }

    /// Applies a change made from the rest Live Activity. The added time is recorded once, and a
    /// rest the activity ended is recorded with the outcome it ended with.
    func drainRestActivityChanges() {
        guard let workoutId = activeWorkout?.workoutId else {
            // Nothing to attribute: discard anything the activity left behind rather than
            // recording it against a finished workout.
            _ = RestActivityStore.takeExtension()
            _ = RestActivityStore.takeCompletion()
            return
        }
        if let seconds = RestActivityStore.takeExtension() {
            recordRestExtension(seconds)
        }
        if let result = restTimer.reconcileExternalChanges(workoutId: workoutId) {
            recordRestResult(result)
        }
    }

    private func handleRestNotificationDone() {
        if restTimer.startedAt != nil {
            _ = restTimer.finish(outcome: "completed")
        } else {
            RestNotificationManager.shared.acknowledgeDelivered()
        }
    }

    private func restISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: Phase 2 mutations

    func saveReadiness(
        values: [String: Double],
        note: String?,
        idempotencyKey: String
    ) async -> Bool {
        guard !isSaving, let session else { return false }
        guard permitsMutation(kind: .readiness, operationId: idempotencyKey) else {
            return false
        }
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
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

    // MARK: HealthKit readiness (Phase 3A)

    func setHealthKitEnabled(_ enabled: Bool) async {
        guard enabled != healthKitEnabled else { return }
        if !enabled {
            healthKitDefaults.set(false, forKey: Self.healthKitDefaultsKey)
            healthKitEnabled = false
            healthKitSelection = nil
            healthKitState = .featureDisabled
            healthKitOperation = OperationKey<HealthKitReadinessRequest>()
            healthKitFollowUp = false
            return
        }
        guard canUseHealthKit else {
            healthKitState = .unavailable
            return
        }
        healthKitDefaults.set(true, forKey: Self.healthKitDefaultsKey)
        healthKitEnabled = true
        healthKitState = .enabled
        healthKitOperation = OperationKey<HealthKitReadinessRequest>()
        do {
            try await healthKit.requestAuthorization()
        } catch {
            healthKitState = .importError(message(for: error))
            return
        }
        await importHealthKit()
    }

    func refreshWithHealthKit() async {
        let outcome = await refresh()
        guard outcome.succeeded, healthKitEnabled else { return }
        await importHealthKit()
    }

    func importHealthKit() async {
        guard healthKitEnabled else {
            healthKitState = .featureDisabled
            return
        }
        guard canUseHealthKit else {
            healthKitState = .unavailable
            return
        }
        guard let session, let date = today?.date else {
            healthKitState = .importError("Refresh Today before importing HealthKit readiness.")
            return
        }
        if isImportingHealthKit {
            healthKitFollowUp = true
            return
        }
        await runHealthKitImport(session: session, date: date)
        while healthKitFollowUp {
            healthKitFollowUp = false
            guard healthKitEnabled, canUseHealthKit,
                  let currentSession = self.session,
                  let currentDate = today?.date else { break }
            await runHealthKitImport(session: currentSession, date: currentDate)
        }
    }

    /// A queued HealthKit import is always superseded by the next one: its body may carry a date
    /// the server no longer accepts, so it can never replay, and leaving it in place blocks every
    /// later import behind a write that cannot succeed. The new import is idempotent and carries
    /// today's values, so dropping the old one loses nothing.
    private func discardSupersededHealthKitWrites(session: IOSSession) {
        let pending = client.pendingMutations(for: session)
        guard pending.contains(where: { $0.kind == .healthkitReadiness }) else { return }
        for entry in pending where entry.kind == .healthkitReadiness {
            client.discard(entry)
        }
        refreshPendingMutations()
        if pendingMutations.isEmpty {
            recoveryMessage = nil
        }
    }

    private func runHealthKitImport(session: IOSSession, date: String) async {
        isImportingHealthKit = true
        healthKitRefreshError = nil
        var lockHeld = false
        defer {
            if lockHeld { releaseReadinessLock() }
            isImportingHealthKit = false
            refreshPendingMutations()
        }
        await acquireReadinessLock()
        lockHeld = true
        discardSupersededHealthKitWrites(session: session)
        do {
            // The recovery series is what readiness reads, so the last few nights go up before
            // the readiness import and its response can show them. The backfill is bounded and
            // resumable, and runs beside the import rather than delaying it.
            recovery.prepare(for: session.baseURL.absoluteString)
            await recovery.syncRecent(session: session)
            Task { await recovery.backfill(session: session) }
            let selection = try await healthKit.selectSamples(
                serverDate: date,
                now: Date()
            )
            healthKitSelection = selection
            if selection.isEmpty {
                healthKitState = selection.hasStaleSample ? .staleSample : .noEligibleSample
                return
            }
            healthKitState = .eligibleSample
            let request = HealthKitReadinessRequest(
                date: date,
                samples: selection.observations.map(\.payload)
            )
            let key = healthKitOperation.use(request)
            guard permitsMutation(kind: .healthkitReadiness, operationId: key) else {
                healthKitState = .importError(
                    mutationError
                        ?? "A previous write was not confirmed. Retry or discard it on Today."
                )
                return
            }
            _ = try await client.importHealthKitReadiness(
                request,
                session: session,
                idempotencyKey: key
            )
            healthKitOperation.acknowledged()
            mutationError = nil
            // The mutation is acknowledged and journaled before the refresh. A failed GET is
            // recoverable and must not turn a successful POST into a retry.
            lockHeld = false
            releaseReadinessLock()
            let outcome = await refresh()
            if outcome.succeeded {
                healthKitRefreshError = nil
            } else {
                healthKitRefreshError = outcome.message
                    ?? "Readiness was saved, but the authoritative refresh failed."
            }
        } catch {
            healthKitState = .importError(message(for: error))
            handleMutation(error)
        }
    }

    func issuePrescription(
        readinessAck: Bool,
        confirmations: [String: Bool]? = nil,
        settings: PlanSettings? = nil,
        executionTarget: PrescriptionExecutionTarget = .phone,
        idempotencyKey: String
    ) async {
        guard !isSaving, let session else { return }
        guard !hasPendingOfflineCapture else {
            mutationError = "Resolve or discard the pending offline capture before requesting another workout."
            return
        }
        guard permitsMutation(kind: .prescription, operationId: idempotencyKey) else {
            return
        }
        let settings = settings ?? PlanSettings()
        isSaving = true
        mutationFailureAmbiguous = false
        defer {
            isSaving = false
            refreshPendingMutations()
        }
        mutationError = nil
        do {
            let ack = try await client.issuePrescription(
                IssuePrescriptionRequest(
                    readinessAck: readinessAck,
                    confirmations: confirmations,
                    settings: settings,
                    executionTarget: executionTarget
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
            planSettings = ack.settings ?? settings
            prescriptionState = .generating(
                PlanProgress(
                    issuedPlanId: ack.issuedPlanId,
                    status: ack.status,
                    elapsedSeconds: 0,
                    settings: planSettings
                )
            )
            startPlanPolling()
            // Wait for the request to settle. The UI is not blocked — the model publishes the
            // generating card while this awaits — and "Stop waiting"/expiry cancels the poll.
            await planPollTask?.value
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
        stopPlanPolling()
        prescriptionState = .idle
        mutationError = nil
        mutationFailureAmbiguous = false
    }

    // MARK: Plan request (R7)

    /// Poll cadence for a request in flight. 60 s is a copy threshold, not a timeout, so a slow
    /// build keeps polling until the server reports a terminal state (contract section 5).
    static func planPollIntervalMs(elapsedSeconds: Int) -> Int {
        if elapsedSeconds < 10 { return 1_000 }
        if elapsedSeconds < 60 { return 2_000 }
        if elapsedSeconds < 300 { return 5_000 }
        return 10_000
    }

    private func startPlanPolling() {
        planPollTask?.cancel()
        planPollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollPlanUntilSettled()
        }
    }

    private func stopPlanPolling() {
        planPollTask?.cancel()
        planPollTask = nil
    }

    private var planElapsedSeconds: Int {
        if case .generating(let progress) = prescriptionState {
            return progress.elapsedSeconds
        }
        return 0
    }

    private func pollPlanUntilSettled() async {
        while !Task.isCancelled {
            let interval = Self.planPollIntervalMs(elapsedSeconds: planElapsedSeconds)
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            if Task.isCancelled { return }
            if await pollPlanOnce() { return }
        }
    }

    /// One authoritative read. Returns true when the request reached a terminal state.
    private func pollPlanOnce() async -> Bool {
        guard let session else { return true }
        do {
            let state = try await client.planState(session: session)
            planPollFailures = 0
            applyPlanState(state)
            switch state.status {
            case "queued", "building":
                return false
            default:
                return true
            }
        } catch let error as APIError where error.isAuthenticationFailure {
            handle(error)
            return true
        } catch {
            // A failed read is not a failed request: the plan may already exist, so keep
            // waiting. Ten consecutive failures is not a blip though, and spinning forever
            // would hide a real problem behind a card that never resolves.
            planPollFailures += 1
            if planPollFailures >= Self.maxPlanPollFailures {
                stopPlanPolling()
                prescriptionState = .failed(
                    "Could not read the plan state. The request may still finish; refresh to check."
                )
                return true
            }
            return false
        }
    }

    /// Apply the authoritative plan state. The server, not a local copy, decides what is shown.
    func applyPlanState(_ state: PlansStateResponse) {
        switch state.status {
        case "ready":
            if let issued = state.issuedPlan {
                stopPlanPolling()
                prescriptionState = .issued(issued)
            } else {
                stopPlanPolling()
                prescriptionState = .failed("The server reported a ready plan without a plan body.")
            }
        case "queued", "building":
            prescriptionState = .generating(
                PlanProgress(
                    issuedPlanId: state.issuedPlanId ?? planElapsedSettingsID,
                    status: state.status,
                    elapsedSeconds: state.elapsedSeconds ?? 0,
                    settings: state.settings ?? planSettings
                )
            )
        case "error":
            stopPlanPolling()
            prescriptionState = .failed(
                state.error?.message ?? "The plan could not be generated."
            )
        default:
            // "none": no live request. Drop a stale preview instead of offering Start on it.
            stopPlanPolling()
            if case .issued = prescriptionState {
                prescriptionState = .idle
            }
            if case .generating = prescriptionState {
                prescriptionState = .idle
            }
        }
    }

    private var planElapsedSettingsID: String {
        if case .generating(let progress) = prescriptionState {
            return progress.issuedPlanId
        }
        return ""
    }

    /// Reconcile against the server after launch or foreground. Never overrides a live request
    /// with local state (contract section 6).
    func reconcilePlanState() async {
        guard let session else { return }
        guard let state = try? await client.planState(session: session) else { return }
        applyPlanState(state)
        resumePlanPollingIfNeeded()
    }

    private func resumePlanPollingIfNeeded() {
        if case .generating = prescriptionState {
            startPlanPolling()
        }
    }

    func startWorkout(idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, case .issued(let issued) = prescriptionState else {
            return false
        }
        guard !hasPendingOfflineCapture else {
            mutationError = "Resolve or discard the pending offline capture before starting another workout."
            return false
        }
        guard permitsMutation(kind: .startWorkout, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let workout = try await client.startWorkout(
                issuedPlanId: issued.issuedPlanId,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(workout))
            await automation.handle(.started, sessionID: workout.workoutId)
            clearOfflineCaptureAfterServerCompletion()
            persistActiveWorkout()
            recoveryIssue = nil
            workoutRefreshGrace = true
            await refresh()
            // The plan is consumed by the start. Clear the ready state after reconciliation so a
            // stale fake/current plan read cannot put the start affordance back on Today.
            prescriptionState = .idle
            RestNotificationManager.shared.requestAuthorizationIfNeeded()
            return true
        } catch {
            if let api = error as? APIError, api.isAuthenticationFailure {
                handle(error)
                return false
            }
            if let api = error as? APIError {
                let code = api.code ?? ""
                if ["plan_consumed", "plan_expired", "plan_superseded"].contains(code) {
                    prescriptionState = .idle
                    recoveryIssue = .prescriptionUnavailable(
                        reason: "This prescription is no longer available. Refresh to load the current server state."
                    )
                    await refresh()
                } else if code == "workout_active" {
                    prescriptionState = .idle
                    await refresh()
                }
            }
            handleMutation(error)
            return false
        }
    }

    func addSet(_ body: AddSetRequest, idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        guard !isMirroringWatchSession else {
            mutationError = "Logging is on the Apple Watch. Take over logging to record sets here."
            return false
        }
        if offlineCaptureActive {
            return queueAddSet(body, idempotencyKey: idempotencyKey, workout: workout)
        }
        guard permitsMutation(kind: .addSet, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.addSet(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(updated))
            workoutRefreshGrace = true
            persistActiveWorkout()
            return true
        } catch {
            if shouldQueueOffline(error) {
                client.discardPendingOperation(idempotencyKey)
                return queueAddSet(body, idempotencyKey: idempotencyKey, workout: workout)
            }
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func removeSet(
        workoutId: String,
        setId: Int,
        idempotencyKey: String
    ) async -> Bool {
        guard !isSaving, let session else { return false }
        guard !isMirroringWatchSession else {
            mutationError = "Sets are recorded on the Apple Watch. Take over logging to change them here."
            return false
        }
        guard !offlineCaptureActive else {
            mutationError = "Removing a server-confirmed set requires a connection. Pending local sets can still be removed."
            return false
        }
        guard permitsMutation(kind: .removeSet, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.removeSet(
                workoutId: workoutId,
                body: RemoveSetRequest(setId: setId),
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(updated))
            workoutRefreshGrace = true
            persistActiveWorkout()
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func rateForm(_ body: FormRatingRequest, idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        // Ownership is checked before the offline branch: a mirror must not queue a phone-side
        // form rating that the server would reject later.
        guard !isMirroringWatchSession else {
            mutationError = "Form ratings are recorded on the Apple Watch. Take over logging to rate here."
            return false
        }
        if offlineCaptureActive {
            return queueForm(body, idempotencyKey: idempotencyKey, workout: workout)
        }
        guard permitsMutation(kind: .rateForm, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.rateForm(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(updated))
            workoutRefreshGrace = true
            persistActiveWorkout()
            return true
        } catch {
            if shouldQueueOffline(error) {
                client.discardPendingOperation(idempotencyKey)
                return queueForm(body, idempotencyKey: idempotencyKey, workout: workout)
            }
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func loadExerciseCatalogue(force: Bool = false) async {
        guard let session else { return }
        let server = session.baseURL.absoluteString
        if !force && !exerciseCatalogue.isEmpty { return }
        if force {
            // Configuration is cached in memory for the session; an explicit catalogue
            // refresh invalidates it so detail screens do not keep showing old taxonomy.
            exerciseDetailCache.removeAll()
        }
        if exerciseCatalogue.isEmpty, exerciseCatalogueLoadedServerURL != server {
            if let cached = exerciseCatalogueCache.load(serverURL: server) {
                exerciseCatalogue = cached.exercises
                exerciseCatalogueCachedAt = cached.fetchedAt
                await ExerciseSpotlightIndexer.index(cached.exercises)
            }
            exerciseCatalogueLoadedServerURL = server
        }
        guard !isLoadingExerciseCatalogue else { return }
        isLoadingExerciseCatalogue = true
        exerciseCatalogueError = nil
        defer { isLoadingExerciseCatalogue = false }
        do {
            let exercises = try await client.exerciseCatalogue(session: session).exercises
            exerciseCatalogue = exercises
            exerciseCatalogueCachedAt = nil
            exerciseCatalogueLoadedServerURL = server
            try? exerciseCatalogueCache.save(serverURL: server, exercises: exercises)
            await ExerciseSpotlightIndexer.index(exercises)
        } catch {
            if exerciseCatalogue.isEmpty {
                exerciseCatalogueError = message(for: error)
            }
            if let api = error as? APIError, api.isAuthenticationFailure {
                forgetLocally(message: api.errorDescription)
            }
        }
    }

    func loadExerciseDetail(exerciseId: String) async {
        guard let session else { return }
        exerciseDetail = exerciseDetailCache[exerciseId]
        guard !isLoadingExerciseDetail else { return }
        isLoadingExerciseDetail = true
        exerciseDetailError = nil
        defer { isLoadingExerciseDetail = false }
        do {
            let detail = try await client.exerciseDetail(
                exerciseId: exerciseId, session: session
            )
            exerciseDetailCache[exerciseId] = detail
            exerciseDetail = detail
        } catch {
            exerciseDetailError = message(for: error)
            if let api = error as? APIError, api.isAuthenticationFailure {
                forgetLocally(message: api.errorDescription)
            }
        }
    }

    func loadExerciseHistory(exerciseId: String, reset: Bool = false) async {
        guard let session else { return }
        if reset || exerciseHistoryExerciseId != exerciseId {
            exerciseHistoryExerciseId = exerciseId
            exerciseHistorySessions = []
            exerciseHistoryIncluded = []
            exerciseHistoryTotal = 0
            exerciseHistoryHasMore = false
            exerciseHistoryError = nil
        }
        guard !isLoadingExerciseHistory else { return }
        isLoadingExerciseHistory = true
        if reset {
            exerciseHistoryError = nil
        }
        defer { isLoadingExerciseHistory = false }
        do {
            let offset = reset ? 0 : exerciseHistorySessions.count
            let response = try await client.exerciseHistory(
                exerciseId: exerciseId,
                limit: 20,
                offset: offset,
                session: session
            )
            if reset {
                exerciseHistorySessions = response.sessions
            } else {
                let existing = Set(exerciseHistorySessions.map(\.sessionId))
                exerciseHistorySessions += response.sessions.filter {
                    !existing.contains($0.sessionId)
                }
            }
            exerciseHistoryIncluded = response.includedExercises
            exerciseHistoryTotal = response.total
            exerciseHistoryHasMore = response.hasMore
        } catch {
            exerciseHistoryError = message(for: error)
            if let api = error as? APIError, api.isAuthenticationFailure {
                forgetLocally(message: api.errorDescription)
            }
        }
    }

    func swapPlanExercise(
        workoutId: String,
        itemIndex: Int,
        exerciseId: String,
        expectedExerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.swapPlanExercise(
                workoutId: workoutId,
                itemIndex: itemIndex,
                body: PlanSwapRequest(
                    exerciseId: exerciseId,
                    expectedExerciseId: expectedExerciseId
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    func removePlanExercise(
        workoutId: String,
        itemIndex: Int,
        expectedExerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.removePlanExercise(
                workoutId: workoutId,
                itemIndex: itemIndex,
                body: PlanRemoveRequest(expectedExerciseId: expectedExerciseId),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    func changePlanSets(
        workoutId: String,
        itemIndex: Int,
        delta: Int,
        expectedExerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.changePlanSets(
                workoutId: workoutId,
                itemIndex: itemIndex,
                body: PlanSetsRequest(
                    delta: delta,
                    expectedExerciseId: expectedExerciseId
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    func movePlanExercise(
        workoutId: String,
        itemIndex: Int,
        toIndex: Int,
        expectedExerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.movePlanExercise(
                workoutId: workoutId,
                itemIndex: itemIndex,
                body: PlanMoveRequest(
                    toIndex: toIndex,
                    expectedExerciseId: expectedExerciseId
                ),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    func addPlanExercise(
        workoutId: String,
        exerciseId: String,
        idempotencyKey: String
    ) async -> Bool {
        guard let session else { return false }
        return await performPlanEdit(idempotencyKey: idempotencyKey) {
            try await client.addPlanExercise(
                workoutId: workoutId,
                body: PlanAddRequest(exerciseId: exerciseId),
                session: session,
                idempotencyKey: idempotencyKey
            )
        }
    }

    private func performPlanEdit(
        idempotencyKey: String,
        _ operation: () async throws -> WorkoutDetail
    ) async -> Bool {
        guard !isSaving, session != nil, activeWorkout != nil else { return false }
        guard !offlineCaptureActive else {
            mutationError = "Plan editing requires the server."
            return false
        }
        guard permitsMutation(kind: .planEdit, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await operation()
            _ = apply(.operationSucceeded(updated))
            workoutRefreshGrace = true
            persistActiveWorkout()
            pushExecutionToWatch()
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed", "plan_changed",
                "sets_already_logged", "sets_below_logged", "last_plan_item",
                "exercise_already_present"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func completeWorkout(
        _ body: CompleteWorkoutRequest,
        idempotencyKey: String
    ) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        guard !isMirroringWatchSession else {
            mutationError = "This workout is logged on the Apple Watch. Take over logging to finish it here."
            return false
        }
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        // An open exercise would otherwise be recorded as started and never completed.
        endAllExercises()
        // Execution events queued before finish must reach the server first; the API accepts
        // late events but the local replay path needs an active workout to flush them.
        if hasPendingOfflineCapture {
            await syncOfflineCapture()
        }
        if offlineCaptureActive {
            restTimer.dismiss()
            let queued = queueFinish(body, idempotencyKey: idempotencyKey, workout: workout)
            if queued {
                await automation.handle(.ended, sessionID: workout.workoutId)
            }
            return queued
        }
        guard permitsMutation(kind: .completeWorkout, operationId: idempotencyKey) else {
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.completeWorkout(
                workoutId: workout.workoutId,
                body: body,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(updated))
            await automation.handle(.ended, sessionID: workout.workoutId)
            recoveryIssue = nil
            workoutRefreshGrace = false
            restTimer.dismiss()
            clearOfflineCaptureAfterServerCompletion()
            nudges.recordSessionCompleted()
            await refresh()
            await loadHistory(reset: true)
            return true
        } catch {
            if shouldQueueOffline(error) {
                client.discardPendingOperation(idempotencyKey)
                let queued = queueFinish(body, idempotencyKey: idempotencyKey, workout: workout)
                if queued {
                    await automation.handle(.ended, sessionID: workout.workoutId)
                }
                return queued
            }
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
            handleMutation(error)
            return false
        }
    }

    func abandonWorkout(idempotencyKey: String) async -> Bool {
        guard !isSaving, let session, let workout = activeWorkout else { return false }
        guard permitsMutation(kind: .abandonWorkout, operationId: idempotencyKey) else {
            return false
        }
        if hasPendingOfflineCapture {
            await syncOfflineCapture()
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.abandonWorkout(
                workoutId: workout.workoutId,
                session: session,
                idempotencyKey: idempotencyKey
            )
            _ = apply(.operationSucceeded(updated))
            await automation.handle(.ended, sessionID: workout.workoutId)
            clearOfflineCaptureAfterServerCompletion()
            recoveryIssue = nil
            workoutRefreshGrace = false
            restTimer.dismiss()
            activeExercises = []
            persistActiveExercises()
            await refresh()
            return true
        } catch {
            if let api = error as? APIError,
               ["workout_not_active", "plan_consumed"].contains(api.code ?? "") {
                await refresh()
            }
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

    /// A shortcut or Action button asked to see the running workout. The Today screen observes this
    /// and pushes the active workout, which is where finish and sRPE live.
    @Published private(set) var openActiveWorkoutRequest = 0

    func requestOpenActiveWorkout() {
        openActiveWorkoutRequest += 1
    }

    /// Pushes a changed scene choice to the watch. Best-effort; pairing errors are already surfaced
    /// by the watch section.
    func syncSceneMappingToWatch() {
        Task { await watchPairing.syncSceneMapping() }
    }

    func makeNarrativeGenerator() -> any NarrativeGenerating {
        FoundationNarrativeGenerator()
    }

    func explain(_ question: String) async throws -> ExplainResponse {
        guard let session else {
            throw APIError.transport("Pair this iPhone with the server first.")
        }
        return try await client.explain(question: question, session: session)
    }

    func makeChatModel() -> TrainingChatModel {
        guard let session else {
            return TrainingChatModel(
                generator: UnavailableChatGenerator(), modelLabel: "Unavailable"
            )
        }
        if chatModelChoice == .deepSeek {
            let key = (try? deepSeekKeyStore.load()) ?? nil
            return TrainingChatModel(
                generator: DeepSeekChatGenerator(
                    api: DeepSeekClient(apiKey: key),
                    keyPresent: key?.isEmpty == false,
                    facts: ChatToolbox(client: client, session: session),
                    includePlan: chatPlanEnabled,
                    includeHealth: chatHealthEnabled
                ),
                modelLabel: "DeepSeek",
                planEnabled: chatPlanEnabled
            )
        }
        return TrainingChatModel(
            generator: FoundationChatGenerator(
                facts: ChatToolbox(client: client, session: session),
                includePlan: chatPlanEnabled
            ),
            modelLabel: "On-device",
            planEnabled: chatPlanEnabled
        )
    }

    func saveDeepSeekKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an API key first." }
        do {
            try deepSeekKeyStore.save(trimmed)
            deepSeekKeyPresent = true
            return "Key saved in this iPhone's Keychain."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "The key could not be saved."
        }
    }

    func removeDeepSeekKey() -> String {
        do {
            try deepSeekKeyStore.delete()
            deepSeekKeyPresent = false
            return "Key removed."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "The key could not be removed."
        }
    }

    func testDeepSeekKey(_ key: String) async -> String {
        let stored = (try? deepSeekKeyStore.load()) ?? nil
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = candidate.isEmpty ? stored : candidate
        guard let selected, !selected.isEmpty else { return "Enter an API key first." }
        do {
            try await DeepSeekClient(apiKey: selected).validateKey()
            return "Key works."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "The key could not be checked."
        }
    }

    func loadOverviewEnvelope() async throws -> IntelligenceEnvelope {
        guard let session else { throw APIError.unauthorized }
        return try await client.overview(session: session)
    }

    /// The weekly review reads through the same paired session; the view owns its load state.
    func makeWeeklyReviewModel() -> WeeklyReviewViewModel {
        WeeklyReviewViewModel { [weak self] weekEnd in
            guard let self, let session = self.session else {
                throw APIError.unauthorized
            }
            return try await self.client.weeklyReview(session: session, weekEnd: weekEnd)
        }
    }

    // MARK: Durable pending operations

    /// Accepts any JSON object; the replayed upload's payload is not needed here.
    private struct JournalReplayAck: Decodable {}

    func recoverPendingMutations() async {
        guard let session, !isRecovering, !isSaving else { return }
        let entries = client.pendingMutations(for: session)
        pendingMutations = entries
        guard !entries.isEmpty else {
            recoveryMessage = nil
            return
        }
        isRecovering = true
        defer {
            isRecovering = false
            refreshPendingMutations()
        }
        var message: String?
        for entry in entries {
            // A queued HealthKit import is always superseded: the next import carries today's
            // values, while the queued body may carry a date the server no longer accepts. Left
            // in place it can never replay and blocks every later write.
            if entry.kind == .healthkitReadiness {
                client.discard(entry)
                continue
            }
            guard entry.state == .pending else {
                message = "\(entry.kind.label) has an unresolved conflict."
                continue
            }
            guard entry.isReplayable else {
                client.markConflict(entry)
                message = "\(entry.kind.label) is older than the safe replay window. Discard it and verify the server state."
                continue
            }
            do {
                switch entry.kind {
                case .readiness, .healthkitReadiness:
                    let _: ReadinessPayload = try await client.replay(entry, session: session)
                case .prescription:
                    // The journal only proves the request was accepted. A Phase 2 receipt may
                    // still return the old synchronous body, so decode the shared field only
                    // and let the authoritative read decide what to show.
                    let ack: PlanAckEnvelope = try await client.replay(entry, session: session)
                    _ = ack
                    await reconcilePlanState()
                case .startWorkout, .addSet, .removeSet, .rateForm, .planEdit, .takeover:
                    activeWorkout = try await client.replay(entry, session: session)
                    workoutRefreshGrace = true
                case .completeWorkout, .abandonWorkout:
                    activeWorkout = try await client.replay(entry, session: session)
                    workoutRefreshGrace = false
                case .executionEvents, .healthkitActivity:
                    // Both are idempotent batch uploads. Leaving them unreplayed stranded the
                    // entry forever and blocked every later write; replay resolves it, and a
                    // rejected batch is removed by the journal failure rules.
                    let _: JournalReplayAck = try await client.replay(entry, session: session)
                }
            } catch let api as APIError {
                if api.code == "idempotency_conflict" {
                    message = "A pending \(entry.kind.label.lowercased()) conflicts with a previous request. Discard it and refresh."
                    break
                }
                if !Self.isAmbiguous(api) {
                    message = api.errorDescription
                    continue
                }
                message = api.errorDescription
                break
            } catch {
                message = self.message(for: error)
                break
            }
        }
        recoveryMessage = message
        await refresh()
    }

    func retryPendingMutations() async {
        await recoverPendingMutations()
    }

    func discardPendingMutations() {
        guard let session else { return }
        client.discardAll(for: session)
        pendingMutations = []
        recoveryMessage = nil
        mutationError = nil
        mutationFailureAmbiguous = false
    }

    func clearRecoveryIssue() {
        recoveryIssue = nil
    }

    func clearWorkoutRecovery() {
        // Clear stale local state; the server remains the authority on the next refresh.
        activeWorkout = nil
        activeExercises = []
        recoveryIssue = nil
        workoutRefreshGrace = false
        mutationError = nil
        persistActiveWorkout()
        persistActiveExercises()
    }

    func abandonRecoveredWorkout() async {
        guard !isSaving, activeWorkout != nil else { return }
        let key = UUID().uuidString.lowercased()
        if await abandonWorkout(idempotencyKey: key) {
            recoveryIssue = nil
        }
    }

    @discardableResult
    private func apply(_ event: SessionEvent) -> [SessionEffect] {
        let current = SessionState(
            activeWorkout: activeWorkout,
            isSaving: isSaving,
            mutationError: mutationError,
            mutationFailureAmbiguous: mutationFailureAmbiguous
        )
        let (next, effects) = SessionReducer.reduce(current, event)
        activeWorkout = next.activeWorkout
        isSaving = next.isSaving
        mutationError = next.mutationError
        mutationFailureAmbiguous = next.mutationFailureAmbiguous
        for effect in effects {
            execute(effect)
        }
        return effects
    }

    private func execute(_ effect: SessionEffect) {
        switch effect {
        case .persistActiveWorkout:
            persistActiveWorkout()
        case .refreshPendingMutations:
            refreshPendingMutations()
        }
    }

    private func refreshPendingMutations() {
        guard let session else {
            pendingMutations = []
            return
        }
        pendingMutations = client.pendingMutations(for: session)
    }

    /// A new mutation may proceed only when there is no unresolved operation, or when this is
    /// the exact operation being retried. This keeps the journal bounded and ordered.
    private func shouldQueueOffline(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return true }
        switch api {
        case .transport, .decoding:
            return true
        case .server(let status, _, _, _, _):
            return status >= 500
        case .http(let status, _, _):
            return status >= 500
        default:
            return false
        }
    }

    private func nowISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func offlineRecoveryBlocksWrites() -> Bool {
        if offlineRecoveryConflict != nil {
            mutationError = "Resolve the offline recovery conflict before adding offline work."
            return true
        }
        guard offlineRecoveryError != nil else { return false }
        mutationError = "Offline recovery data could not be read. Retry recovery or discard the local capture before adding offline work."
        return true
    }

    private func queueAddSet(
        _ body: AddSetRequest,
        idempotencyKey: String,
        workout: WorkoutDetail
    ) -> Bool {
        guard !offlineRecoveryBlocksWrites() else { return false }
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        let performedAt = body.performedAt ?? nowISO()
        let request = AddSetRequest(
            exerciseId: body.exerciseId,
            loadKg: body.loadKg,
            reps: body.reps,
            rir: body.rir,
            velocityMps: body.velocityMps,
            setIndex: body.setIndex,
            planItemIndex: body.planItemIndex,
            repVelocities: body.repVelocities,
            performedAt: performedAt
        )
        do {
            let localId = try offlineStore.nextLocalSetId()
            let localSet = WorkoutSet(
                setId: localId,
                exerciseId: request.exerciseId,
                setIndex: request.setIndex,
                planItemIndex: request.planItemIndex,
                loadKg: request.loadKg,
                reps: request.reps,
                rir: request.rir,
                velocity: request.velocityMps,
                source: "manual",
                repsDetail: nil,
                repSummary: nil
            )
            let updated = workout.replacing(sets: (workout.sets ?? []) + [localSet])
            let operation = OfflineOperation(
                operationId: idempotencyKey,
                workoutId: workout.workoutId,
                body: .addSet(request),
                createdAt: Date(),
                localSetId: localId
            )
            offlineCapture = try offlineStore.record(operation, activeWorkout: updated)
            _ = apply(.operationQueued(updated))
            isOffline = true
            return true
        } catch {
            _ = apply(.operationFailed(message: message(for: error), ambiguous: false))
            return false
        }
    }

    private func queueForm(
        _ body: FormRatingRequest,
        idempotencyKey: String,
        workout: WorkoutDetail
    ) -> Bool {
        guard !offlineRecoveryBlocksWrites() else { return false }
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        do {
            let localId = nextLocalFormId(in: workout)
            let localForm = WorkoutForm(
                formId: localId,
                workoutId: workout.workoutId,
                exerciseId: body.exerciseId,
                rating: body.rating,
                note: body.note
            )
            var forms = (workout.forms ?? []).filter {
                $0.exerciseId != body.exerciseId
            }
            forms.append(localForm)
            let updated = workout.replacing(forms: forms)
            let operation = OfflineOperation(
                operationId: idempotencyKey,
                workoutId: workout.workoutId,
                body: .rateForm(body),
                createdAt: Date(),
                localFormId: localId
            )
            offlineCapture = try offlineStore.record(operation, activeWorkout: updated)
            _ = apply(.operationQueued(updated))
            isOffline = true
            return true
        } catch {
            _ = apply(.operationFailed(message: message(for: error), ambiguous: false))
            return false
        }
    }

    private func queueFinish(
        _ body: CompleteWorkoutRequest,
        idempotencyKey: String,
        workout: WorkoutDetail
    ) -> Bool {
        guard !offlineRecoveryBlocksWrites() else { return false }
        guard !offlineFinishPending else {
            mutationError = "This workout is already queued for finish."
            return false
        }
        let request = CompleteWorkoutRequest(
            sessionRpe: body.sessionRpe,
            notRecorded: body.notRecorded,
            durationMin: body.durationMin,
            notes: body.notes,
            endedAt: body.endedAt ?? nowISO()
        )
        do {
            let operation = OfflineOperation(
                operationId: idempotencyKey,
                workoutId: workout.workoutId,
                body: .completeWorkout(request),
                createdAt: Date()
            )
            offlineCapture = try offlineStore.record(operation, activeWorkout: workout)
            _ = apply(.operationQueued(workout))
            isOffline = true
            return true
        } catch {
            _ = apply(.operationFailed(message: message(for: error), ambiguous: false))
            return false
        }
    }

    private func nextLocalFormId(in workout: WorkoutDetail) -> Int {
        let used = Set((workout.forms ?? []).compactMap(\.formId).filter { $0 < 0 })
        var candidate = -1
        while used.contains(candidate) { candidate -= 1 }
        return candidate
    }

    func syncOfflineCapture() async {
        guard offlineRecoveryError == nil, offlineRecoveryConflict == nil else { return }
        guard !isSaving, !isSyncingOffline,
              let session, let cached = activeWorkout,
              hasPendingOfflineCapture else { return }
        isSyncingOffline = true
        offlineSyncError = nil
        defer { isSyncingOffline = false }
        do {
            let serverToday = try await client.today(session: session)
            guard let serverActive = serverToday.activeWorkout,
                  serverActive.workoutId == cached.workoutId else {
                offlineSyncError = "The server no longer has this workout active. The local capture was kept; resolve it below."
                return
            }
            for operation in pendingOfflineOperations {
                if operation.state == .expired {
                    if operation.kind == .rateForm {
                        continue
                    }
                    offlineSyncError = "An offline operation is older than the 28-day replay window. Reconcile or discard it before continuing."
                    break
                }
                if operation.state == .failed {
                    continue
                }
                if operation.state == .conflict {
                    break
                }
                if !operation.isReplayable(now: Date()) {
                    offlineCapture = try? offlineStore.updateState(
                        operationId: operation.operationId,
                        state: .expired,
                        error: "Older than the 28-day replay window; reconcile or discard it."
                    )
                    if operation.kind == .rateForm { continue }
                    offlineSyncError = "An offline operation is older than the 28-day replay window. Reconcile or discard it before continuing."
                    break
                }
                _ = try offlineStore.markAttempted(operation.operationId)
                do {
                    switch operation.body {
                    case .addSet(let body):
                        let updated = try await client.addSet(
                            workoutId: operation.workoutId,
                            body: body,
                            session: session,
                            idempotencyKey: operation.operationId,
                            journaling: false
                        )
                        activeWorkout = updated
                        offlineCapture = try offlineStore.remove(operation.operationId)
                        offlineCapture = try offlineStore.setActiveWorkout(updated)
                    case .executionEvents(let events):
                        _ = try await client.submitExecutionEvents(
                            workoutId: operation.workoutId,
                            events: events,
                            session: session,
                            idempotencyKey: operation.operationId
                        )
                        offlineCapture = try offlineStore.remove(operation.operationId)
                    case .rateForm(let body):
                        let updated = try await client.rateForm(
                            workoutId: operation.workoutId,
                            body: body,
                            session: session,
                            idempotencyKey: operation.operationId,
                            journaling: false
                        )
                        activeWorkout = updated
                        offlineCapture = try offlineStore.remove(operation.operationId)
                        offlineCapture = try offlineStore.setActiveWorkout(updated)
                    case .completeWorkout(let body):
                        _ = try await client.completeWorkout(
                            workoutId: operation.workoutId,
                            body: body,
                            session: session,
                            idempotencyKey: operation.operationId,
                            journaling: false
                        )
                        _ = try? offlineStore.remove(operation.operationId)
                        offlineCapture = try? offlineStore.setActiveWorkout(nil)
                        activeWorkout = nil
                        if hasPendingOfflineCapture {
                            offlineSyncError = "The workout finished on the server, but some local operations still need attention."
                        } else {
                            clearOfflineCaptureAfterServerCompletion()
                        }
                        await refresh()
                        await loadHistory(reset: true)
                        return
                    }
                } catch {
                    if error is APIError, !shouldQueueOffline(error) {
                        if operation.kind == .rateForm {
                            offlineCapture = try? offlineStore.updateState(
                                operationId: operation.operationId,
                                state: .failed,
                                error: message(for: error)
                            )
                            continue
                        }
                        offlineCapture = try? offlineStore.updateState(
                            operationId: operation.operationId,
                            state: .conflict,
                            error: message(for: error)
                        )
                        offlineSyncError = message(for: error)
                        break
                    }
                    _ = try? offlineStore.updateState(
                        operationId: operation.operationId,
                        state: .pending,
                        error: message(for: error)
                    )
                    offlineCapture = try? offlineStore.load()
                    isOffline = true
                    offlineSyncError = message(for: error)
                    scheduleOfflineRetry()
                    break
                }
            }
            offlineCapture = try? offlineStore.load()
            if !hasPendingOfflineCapture {
                offlineRetryAttempt = 0
                offlineRetryTask?.cancel()
                isOffline = false
                offlineSyncError = nil
            } else if offlineSyncError == nil {
                isOffline = false
            }
        } catch {
            isOffline = true
            offlineSyncError = message(for: error)
        }
    }

    func retryOfflineOperation(_ operationId: String) async -> Bool {
        guard pendingOfflineOperations.first(where: {
            $0.operationId == operationId
        })?.state != .expired else {
            mutationError = "Expired offline work cannot be replayed; reconcile or discard it."
            return false
        }
        do {
            offlineCapture = try offlineStore.updateState(
                operationId: operationId,
                state: .pending,
                error: nil
            )
            offlineSyncError = nil
            await syncOfflineCapture()
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    private func scheduleOfflineRetry() {
        guard hasPendingOfflineCapture, offlineRetryAttempt < 4 else { return }
        let delay = [2, 5, 10, 30][offlineRetryAttempt]
        offlineRetryAttempt += 1
        offlineRetryTask?.cancel()
        offlineRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncOfflineCapture()
        }
    }

    func discardOfflineOperation(_ operationId: String) async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.operationId == operationId
        }) else { return false }
        do {
            var updated = activeWorkout
            if let localSetId = operation.localSetId {
                updated = updated?.replacing(sets: (updated?.sets ?? []).filter {
                    $0.setId != localSetId
                })
            }
            if let localFormId = operation.localFormId {
                updated = updated?.replacing(forms: (updated?.forms ?? []).filter {
                    $0.formId != localFormId
                })
            }
            _ = try offlineStore.remove(operationId)
            if let updated {
                offlineCapture = try offlineStore.setActiveWorkout(updated)
                activeWorkout = updated
            } else {
                offlineCapture = try offlineStore.load()
            }
            if !hasPendingOfflineCapture {
                isOffline = false
                offlineSyncError = nil
            }
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    func discardAllOfflineCapture() async -> Bool {
        do {
            try offlineStore.clear()
        } catch let error as OfflineCaptureStoreError {
            offlinePersistenceError = error.errorDescription
            mutationError = message(for: error)
            return false
        } catch {
            offlinePersistenceError = OfflineCaptureStoreError.io(
                error.localizedDescription
            ).errorDescription
            mutationError = message(for: error)
            return false
        }
        do {
            offlineCapture = try offlineStore.load()
            offlineRecoveryError = nil
            offlinePersistenceError = nil
            offlineRecoveryConflict = nil
            offlineTelemetryError = nil
            activeWorkout = nil
            offlineSyncError = nil
            isOffline = false
            await refresh()
            return true
        } catch let error as OfflineCaptureStoreError {
            offlineRecoveryError = error
            mutationError = message(for: error)
            return false
        } catch {
            offlineRecoveryError = .io(error.localizedDescription)
            mutationError = message(for: error)
            return false
        }
    }

    func cancelOfflineOperation(_ operationId: String) async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.operationId == operationId
        }), operation.isCancellable else {
            mutationError = "Only unsent offline work can be cancelled."
            return false
        }
        do {
            var updated = activeWorkout
            if let localSetId = operation.localSetId {
                updated = updated?.replacing(sets: (updated?.sets ?? []).filter {
                    $0.setId != localSetId
                })
            }
            if let localFormId = operation.localFormId {
                updated = updated?.replacing(forms: (updated?.forms ?? []).filter {
                    $0.formId != localFormId
                })
            }
            _ = try offlineStore.cancel(operationId)
            if let updated {
                offlineCapture = try offlineStore.setActiveWorkout(updated)
                activeWorkout = updated
            } else {
                offlineCapture = try offlineStore.load()
            }
            if !hasPendingOfflineCapture { isOffline = false }
            mutationError = nil
            return true
        } catch {
            mutationError = message(for: error)
            return false
        }
    }

    func cancelOfflineSet(localSetId: Int) async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.localSetId == localSetId
        }) else { return false }
        return await cancelOfflineOperation(operation.operationId)
    }

    func cancelOfflineFinish() async -> Bool {
        guard let operation = pendingOfflineOperations.first(where: {
            $0.kind == .completeWorkout
        }) else { return false }
        return await cancelOfflineOperation(operation.operationId)
    }

    /// A watch-owned session is logged on the watch; the phone mirrors it and may edit the plan.
    var isMirroringWatchSession: Bool {
        MirrorPolicy.isMirror(workout: activeWorkout, phoneDeviceID: device?.deviceID)
    }

    /// Nudges the watch with the new plan after a phone edit. Best effort and redundant by
    /// design: the watch also refreshes on foreground and after each set (contract §10.2), so a
    /// dropped payload costs one stale view, never a lost edit.
    private func pushExecutionToWatch() {
        // Push after any plan edit, whether the watch owns capture or is read-only; the watch
        // mirrors the plan in both states and its read-only path now applies revisions.
        guard let workout = activeWorkout else { return }
        watchPairing.pushExecution(workout)
    }

    /// Takes logging back from the watch. The watch turns read-only on its next refresh.
    func takeOverLogging() async -> Bool {
        guard let session, let workout = activeWorkout, !isSaving else { return false }
        guard !offlineCaptureActive else {
            mutationError = "Taking over logging requires the server."
            return false
        }
        _ = apply(.operationBegan)
        defer { _ = apply(.operationEnded) }
        do {
            let updated = try await client.takeover(
                workoutId: workout.workoutId,
                session: session,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            _ = apply(.operationSucceeded(updated))
            workoutRefreshGrace = true
            persistActiveWorkout()
            // Tell an open watch immediately; otherwise it keeps writing until its next
            // foreground/refresh, even though the server now assigns ownership to the phone.
            watchPairing.pushExecution(updated)
            mutationError = nil
            return true
        } catch {
            mutationError = (error as? LocalizedError)?.errorDescription
                ?? "Logging could not be taken over."
            return false
        }
    }

    private func permitsMutation(kind: MutationKind, operationId: String) -> Bool {
        // The server allows abandonment from any device (contract §9), and the watch turns
        // read-only on the next refresh. Everything else that writes to a watch-owned session
        // needs the take-over first.
        if isMirroringWatchSession, kind != .planEdit, kind != .abandonWorkout {
            mutationError = "Logging is on the Apple Watch. Take over logging to record sets here."
            return false
        }
        // A HealthKit import is read-derived, idempotent and independent of queued writes. Blocking
        // it behind an unrelated pending operation would strand the owner with nothing to retry.
        if kind == .healthkitReadiness {
            return true
        }
        let unresolved = pendingMutations
        guard !unresolved.isEmpty else { return true }
        if unresolved.contains(where: {
            $0.kind == kind && $0.operationId == operationId && $0.state == .pending
        }) {
            return true
        }
        mutationError = "A previous write was not confirmed. Retry or discard it on Today before starting another."
        return false
    }

    // MARK: Local credential management

    func forgetDevice() {
        forgetLocally(message: nil)
    }

    private func forgetLocally(message: String?) {
        if let session {
            client.discardAll(for: session)
        }
        watchPairing.reset()
        tokens.delete()
        store.device = nil
        store.clearWatchLink()
        device = nil
        session = nil
        bootstrap = nil
        today = nil
        sessions = []
        historyTotal = 0
        historyOffset = 0
        hasLoadedHistory = false
        activeWorkout = nil
        var cleared = false
        do {
            try offlineStore.clear()
            cleared = true
        } catch let error as OfflineCaptureStoreError {
            offlinePersistenceError = error.errorDescription
        } catch {
            offlinePersistenceError = OfflineCaptureStoreError.io(
                error.localizedDescription
            ).errorDescription
        }
        do {
            offlineCapture = try offlineStore.load()
            offlineRecoveryError = nil
            offlineRecoveryConflict = nil
            offlineTelemetryError = nil
            if cleared {
                offlinePersistenceError = nil
            }
        } catch let error as OfflineCaptureStoreError {
            offlineRecoveryError = error
        } catch {
            offlineRecoveryError = .io(error.localizedDescription)
        }
        isOffline = false
        exerciseCatalogue = []
        isLoadingExerciseCatalogue = false
        exerciseCatalogueError = nil
        exerciseCatalogueCachedAt = nil
        exerciseCatalogueLoadedServerURL = nil
        exerciseCatalogueCache.clear()
        exerciseDetail = nil
        isLoadingExerciseDetail = false
        exerciseDetailError = nil
        exerciseHistorySessions = []
        exerciseHistoryIncluded = []
        exerciseHistoryTotal = 0
        exerciseHistoryHasMore = false
        isLoadingExerciseHistory = false
        exerciseHistoryError = nil
        exerciseHistoryExerciseId = nil
        exerciseDetailCache = [:]
        progress = nil
        progressError = nil
        hasLoadedProgress = false
        prescriptionState = .idle
        isSaving = false
        isLoadingProgress = false
        mutationError = nil
        mutationFailureAmbiguous = false
        pendingMutations = []
        recoveryMessage = nil
        recoveryIssue = nil
        isRecovering = false
        workoutRefreshGrace = false
        healthKitDefaults.set(false, forKey: Self.healthKitDefaultsKey)
        healthKitEnabled = false
        healthKitState = .featureDisabled
        healthKitSelection = nil
        healthKitRefreshError = nil
        healthKitOperation = OperationKey<HealthKitReadinessRequest>()
        healthKitFollowUp = false
        pairedServerURL = store.serverURL
        phase = .pairing
        errorMessage = nil
        pairingError = message
    }

    private func handleMutation(_ error: Error) {
        if let api = error as? APIError, api.isAuthenticationFailure {
            _ = apply(.mutationErrorCleared)
            forgetLocally(message: api.errorDescription)
        } else {
            _ = apply(.operationFailed(
                message: message(for: error),
                ambiguous: Self.isAmbiguous(error)
            ))
        }
    }

    /// A transport failure, a decoding failure, or a 5xx may have reached the server even though
    /// the client has no definitive response. A 4xx without a response body is definitive.
    private static func isAmbiguous(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return true }
        switch api {
        case .transport, .decoding:
            return true
        case .http(let status, _, _), .server(let status, _, _, _, _):
            return status >= 500
        case .invalidBaseURL, .invalidPairingCode, .invalidLabel,
             .journal, .unauthorized, .forbidden:
            return false
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
