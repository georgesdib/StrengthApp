import XCTest
import UserNotifications
@testable import StrengthApp
import StrengthCore

@MainActor
private final class FakeNudgeCenter: NudgeCenter {
    private(set) var added: [UNNotificationRequest] = []
    private(set) var pending: [String] = []

    func add(_ request: UNNotificationRequest) async {
        added.append(request)
        pending.append(request.identifier)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        pending.removeAll { identifiers.contains($0) }
    }

    func pendingIdentifiers() async -> [String] { pending }
}

@MainActor
private final class FakeAuthorizer: NotificationAuthorizing {
    var authorized = true
    func status() async -> UNAuthorizationStatus { authorized ? .authorized : .denied }
    func ensureAuthorized() async -> Bool { authorized }
}

private struct FakeGenerator: NudgeGenerating {
    var available = true
    var message: NudgeMessage?

    func availability() -> NarrativeAvailability {
        available ? .available : .unavailable("No model here.")
    }

    func generate(facts: NudgeFacts) async throws -> NudgeMessage {
        guard let message else { throw NarrativeError.failed("No message.") }
        return message
    }
}

@MainActor
final class NudgeSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var center: FakeNudgeCenter!
    private var authorizer: FakeAuthorizer!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "nudge.tests.\(UUID().uuidString)")
        center = FakeNudgeCenter()
        authorizer = FakeAuthorizer()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        super.tearDown()
    }

    // MARK: - Schedule shape

    func testSchedulesOneShotForEachOfSevenDays() async {
        let now = date(2026, 11, 16, 8, 0)
        let scheduler = makeScheduler()
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)

        XCTAssertEqual(center.pending.count, 7, "\(center.pending)")
        let triggers = center.added.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
        XCTAssertEqual(triggers.count, 7)
        XCTAssertTrue(triggers.allSatisfy { !$0.repeats })
        XCTAssertEqual(triggers.first?.dateComponents.hour, 19)
        XCTAssertEqual(triggers.first?.dateComponents.minute, 30)
        XCTAssertEqual(triggers.first?.dateComponents.day, 16)
        XCTAssertEqual(triggers.last?.dateComponents.day, 22)
    }

    func testATimeThatHasPassedStartsTomorrow() async {
        let now = date(2026, 11, 16, 21, 0)
        let scheduler = makeScheduler()
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)

        XCTAssertEqual(center.pending.count, 7)
        let triggers = center.added.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
        XCTAssertEqual(triggers.first?.dateComponents.day, 17)
    }

    func testRebuildIsIdempotent() async {
        let now = date(2026, 11, 16, 8, 0)
        let scheduler = makeScheduler()
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)

        XCTAssertEqual(center.added.count, 7, "an unchanged schedule must not be re-added")
        XCTAssertEqual(center.pending.count, 7)
    }

    func testChangingTheTimeReplacesTheHorizon() async {
        let now = date(2026, 11, 16, 8, 0)
        let scheduler = makeScheduler()
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)
        await scheduler.refresh(enabled: true, hour: 20, minute: 0, facts: facts(), now: now)

        XCTAssertEqual(center.pending.count, 7)
        XCTAssertEqual(Set(center.pending).count, 7)
        let triggers = center.added.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
        XCTAssertEqual(triggers.last?.dateComponents.hour, 20)
    }

    func testAttrainingDayIsSilenced() async {
        let now = date(2026, 11, 16, 8, 0)
        let scheduler = makeScheduler()
        scheduler.recordSessionCompleted(at: date(2026, 11, 16, 7, 0))
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)

        XCTAssertEqual(center.pending.count, 7)
        let triggers = center.added.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
        XCTAssertEqual(triggers.first?.dateComponents.day, 17)
        XCTAssertFalse(center.pending.contains { $0.hasSuffix("2026-11-16") })
    }

    func testASessionInProgressSilencesToday() async {
        let now = date(2026, 11, 16, 8, 0)
        let scheduler = makeScheduler()
        let inProgress = NudgeFacts(readiness: .logged(score: nil), sessionInProgress: true)
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: inProgress, now: now)

        let triggers = center.added.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
        XCTAssertEqual(triggers.first?.dateComponents.day, 17)
    }

    func testDisablingClearsPendingRequests() async {
        let now = date(2026, 11, 16, 8, 0)
        let scheduler = makeScheduler()
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)
        await scheduler.refresh(enabled: false, hour: 19, minute: 30, facts: nil, now: now)

        XCTAssertTrue(center.pending.isEmpty)
    }

    func testUnauthorizedNeverSchedules() async {
        authorizer.authorized = false
        let scheduler = makeScheduler()
        await scheduler.refresh(
            enabled: true, hour: 19, minute: 30, facts: facts(), now: date(2026, 11, 16, 8, 0)
        )
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testDaylightSavingKeepsTheLocalWallClock() async {
        for start in [date(2026, 3, 27, 8, 0), date(2026, 10, 23, 8, 0)] {
            center = FakeNudgeCenter()
            let scheduler = makeScheduler()
            await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: start)
            let triggers = center.added.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
            XCTAssertEqual(triggers.count, 7)
            XCTAssertTrue(
                triggers.allSatisfy {
                    $0.dateComponents.hour == 19 && $0.dateComponents.minute == 30
                },
                "DST moved the reminder: \(triggers.compactMap { $0.dateComponents })"
            )
        }
    }

    func testOccurrencesAreStrictlyIncreasing() {
        let now = date(2026, 11, 16, 8, 0)
        let dates = NudgeSchedule.occurrences(
            hour: 19, minute: 30, count: 7, now: now, calendar: calendar
        )
        XCTAssertEqual(dates.count, 7)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, 7)
    }

    func testOnlyTodaysOccurrenceCarriesTheSpecificMessage() async {
        let now = date(2026, 11, 16, 8, 0)
        let generated = NudgeMessage(
            title: "Squat day", body: "5×5 at 100 kg is waiting for you.", origin: .onDeviceModel
        )
        let scheduler = NudgeScheduler(
            center: center,
            defaults: defaults,
            generator: FakeGenerator(message: generated),
            authorizer: authorizer,
            calendar: calendar
        )
        await scheduler.refresh(enabled: true, hour: 19, minute: 30, facts: facts(), now: now)

        XCTAssertEqual(center.added.first?.content.body, generated.body)
        XCTAssertEqual(center.added.last?.content.body, NudgeCopy.generic().body)
    }

    // MARK: - Readiness detection

    func testReadinessLoggingUsesTheFormedScoreNotThePresenceOfARow() throws {
        // The server omits `known` for any merged row and sets `known:false` only when the day
        // has no row at all. Row presence is not a logged answer: a partial entry merges into a
        // row whose score status is `insufficient`.
        let ready = Data(#"{"date":"2026-11-16","readiness":{"on_date":"2026-11-16","sleep":3,"score":{"status":"ready","score":0.72}}}"#.utf8)
        let logged = try JSONDecoder().decode(TodayResponse.self, from: ready)
        XCTAssertEqual(logged.readiness?.hasEntry, true)
        XCTAssertEqual(logged.readiness?.isLogged, true)

        let partial = Data(#"{"date":"2026-11-16","readiness":{"on_date":"2026-11-16","sleep":3,"score":{"status":"insufficient","score":null}}}"#.utf8)
        let unfinished = try JSONDecoder().decode(TodayResponse.self, from: partial)
        XCTAssertEqual(unfinished.readiness?.hasEntry, true)
        XCTAssertEqual(unfinished.readiness?.isLogged, false)

        let missing = Data(#"{"date":"2026-11-16","readiness":{"on_date":"2026-11-16","known":false}}"#.utf8)
        let empty = try JSONDecoder().decode(TodayResponse.self, from: missing)
        XCTAssertEqual(empty.readiness?.hasEntry, false)
        XCTAssertEqual(empty.readiness?.isLogged, false)
    }

    // MARK: - Copy

    func testTemplateIsDeterministicAndShort() {
        let facts = facts()
        let first = NudgeCopy.message(for: facts)
        XCTAssertEqual(first, NudgeCopy.message(for: facts))
        XCTAssertLessThanOrEqual(first.body.count, NudgeMessage.bodyLimit)
        XCTAssertTrue(first.body.contains("5×5"), first.body)
        XCTAssertEqual(first.origin, .template)
    }

    func testMissingReadinessAsksForReadiness() {
        let message = NudgeCopy.message(for: NudgeFacts(readiness: .missing))
        XCTAssertEqual(message.title, "Log readiness first")
    }

    func testPartialReadinessAsksForTheRest() {
        let message = NudgeCopy.message(for: NudgeFacts(readiness: .partial))
        XCTAssertEqual(message.title, "Finish readiness")
        XCTAssertTrue(message.body.contains("part of today's readiness"))
        XCTAssertTrue(NudgeFacts(readiness: .partial).factText.contains("partly logged"))
    }

    func testEveryTemplateFitsANotification() {
        let shapes: [NudgeFacts] = [
            NudgeFacts(readiness: .missing),
            NudgeFacts(readiness: .partial),
            NudgeFacts(readiness: .logged(score: 72)),
            facts(),
            NudgeFacts(readiness: .logged(score: nil), sessionInProgress: true),
            NudgeFacts(readiness: .missing, planned: .init(label: "Upper", exerciseCount: 6)),
        ]
        for shape in shapes {
            let message = NudgeCopy.message(for: shape)
            XCTAssertLessThanOrEqual(message.title.count, NudgeMessage.titleLimit, message.title)
            XCTAssertLessThanOrEqual(message.body.count, NudgeMessage.bodyLimit, message.body)
        }
    }

    // MARK: - Composer

    func testModelCopyIsUsedWhenItIsGrounded() async {
        let generated = NudgeMessage(
            title: "Squat day", body: "5×5 at 100 kg is waiting for you.", origin: .onDeviceModel
        )
        let composition = await NudgeComposer.compose(
            facts: facts(), generator: FakeGenerator(message: generated)
        )
        XCTAssertEqual(composition.message, generated)
        XCTAssertNil(composition.fallback)
        XCTAssertTrue(composition.usedOnDeviceModel)
    }

    func testNumbersInTheMessageAreAllowed() async {
        // A reminder is encouragement, not an explanation, so it may use numbers the facts do not
        // contain. Facts about a missing readiness entry carry none at all.
        let generated = NudgeMessage(
            title: "Give it 20 minutes",
            body: "Log readiness first, then train. Five minutes of rest between sets is plenty.",
            origin: .onDeviceModel
        )
        let composition = await NudgeComposer.compose(
            facts: NudgeFacts(readiness: .missing),
            generator: FakeGenerator(message: generated)
        )
        XCTAssertEqual(composition.message, generated)
        XCTAssertNil(composition.fallback)
        XCTAssertTrue(composition.usedOnDeviceModel)
    }

    func testAFailedGenerationFallsBackWithItsReason() async {
        let composition = await NudgeComposer.compose(
            facts: facts(), generator: FakeGenerator(message: nil)
        )
        XCTAssertEqual(composition.message, NudgeCopy.message(for: facts()))
        XCTAssertEqual(composition.fallback, .modelFailed("No message."))
    }

    func testUnavailableModelFallsBackToTheTemplate() async {
        let composition = await NudgeComposer.compose(
            facts: facts(), generator: FakeGenerator(available: false)
        )
        XCTAssertEqual(composition.message, NudgeCopy.message(for: facts()))
        XCTAssertEqual(composition.fallback, .modelUnavailable("No model here."))
        XCTAssertFalse(composition.usedOnDeviceModel)
    }

    func testOverlongCopyIsRejected() throws {
        let facts = self.facts()
        let long = NudgeMessage(
            title: "Squat day",
            body: String(repeating: "5 ", count: 100),
            origin: .onDeviceModel
        )
        XCTAssertThrowsError(try NudgeComposer.validate(long))
    }

    // MARK: - Helpers

    private func makeScheduler() -> NudgeScheduler {
        NudgeScheduler(
            center: center,
            defaults: defaults,
            // The simulator cannot run Foundation Models; the template path is what these tests
            // exercise, and the composer tests cover the model path with a stub.
            generator: FakeGenerator(available: false),
            authorizer: authorizer,
            calendar: calendar
        )
    }

    private func facts() -> NudgeFacts {
        NudgeFacts(
            readiness: .logged(score: 72),
            planned: .init(
                label: "Lower",
                exerciseCount: 5,
                focusName: "Back Squat",
                focusSets: 5,
                focusReps: "5",
                focusLoadKg: 100
            )
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }
}
