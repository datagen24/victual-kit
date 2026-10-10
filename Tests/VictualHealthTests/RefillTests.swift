import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualCore
import VictualTestSupport
@testable import VictualHealth

// MARK: Fakes

final class FakeRefillSource: RefillSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _asOf: [CalendarDay] = []
    private var _acks: [String] = []
    var refillsFor: @Sendable (CalendarDay) -> [RefillItem] = { _ in [] }
    var noticesFor: @Sendable (CalendarDay) -> [RefillNotice] = { _ in [] }
    var features: [String] = ["refill", "refill_notices"]
    var capabilitiesError: VictualError?
    var readError: VictualError?
    var ackError: VictualError?

    var asOfSeen: [CalendarDay] { lock.withLock { _asOf } }
    var acks: [String] { lock.withLock { _acks } }

    func capabilities() async throws -> ConsumptionCapabilities {
        if let capabilitiesError { throw capabilitiesError }
        return .init(contractVersion: 1, features: features)
    }

    func refills(asOf: CalendarDay) async throws -> [RefillItem] {
        lock.withLock { _asOf.append(asOf) }
        if let readError { throw readError }
        return refillsFor(asOf)
    }

    func notices(asOf: CalendarDay) async throws -> [RefillNotice] {
        if let readError { throw readError }
        return noticesFor(asOf)
    }

    func acknowledge(noticeKey: String) async throws {
        lock.withLock { _acks.append(noticeKey) }
        if let ackError { throw ackError }
    }

    func fills(recipeID: Int, asOf: CalendarDay) async throws -> [RefillFillRecord] { [] }
}

final class FakeNotificationCenter: RefillNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(id: String, title: String, body: String)] = []
    private var _removed: [String] = []
    private var _removedAll = 0
    var allowed = true

    var posts: [(id: String, title: String, body: String)] { lock.withLock { _posts } }
    var removed: [String] { lock.withLock { _removed } }
    var removedAll: Int { lock.withLock { _removedAll } }

    func isAuthorized() async -> Bool { allowed }
    func requestAuthorization() async -> Bool { allowed }
    func post(identifier: String, title: String, body: String) async throws {
        lock.withLock { _posts.append((identifier, title, body)) }
    }
    func remove(identifiers: [String]) async { lock.withLock { _removed += identifiers } }
    func removeAll() async { lock.withLock { _removedAll += 1 } }
}

/// The recipe's name is what a person typed and may be a medication name.
private let secretName = "Examplepril 10 mg"

private func day(_ text: String) -> CalendarDay { CalendarDay(text)! }

/// The server's side of ADR-0042 §4, so the tests can show what the client's date does.
private func serverItem(reorder: String, lead: Int = 7, asOf: CalendarDay, recipe: Int = 12, order: Bool = false) -> RefillItem {
    let r = day(reorder)
    let status: RefillStatus
    if order { status = .ordered } else if asOf >= r { status = .due } else if asOf >= r.adding(days: -lead) { status = .approaching } else { status = .ok }
    return RefillItem(
        recipeID: recipe, recipeName: secretName, asOf: asOf, asOfSource: .client, status: status,
        daysOverdue: status == .due ? r.days(until: asOf) : nil, reorderDate: r, warningDate: r.adding(days: -lead),
        source: .fallback, unknownReason: nil, leadDays: lead, filledOn: day("2026-01-01"), suppliedDays: 90, openOrder: nil)
}

private func notice(_ recipe: Int, _ kind: RefillNotice.Kind, _ date: String) -> RefillNotice {
    RefillNotice(
        key: "\(recipe):\(kind.rawValue):\(date)", kind: kind, recipeID: recipe, recipeName: secretName,
        reorderDate: day(date), warningDate: nil, daysOverdue: nil, source: .fallback)
}

@MainActor
private func store(
    _ source: FakeRefillSource, _ center: FakeNotificationCenter = FakeNotificationCenter(),
    state: InMemoryRefillStateStore = InMemoryRefillStateStore(),
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) },
    zone: TimeZone = TimeZone(identifier: "UTC")!
) -> RefillStore {
    RefillStore(source: source, notifications: center, stateStore: state, server: "s", account: "me", now: now, zone: { zone })
}

// MARK: Calendar days

@Suite("Calendar days")
struct CalendarDayTests {
    @Test func parsesOnlyRealDates() {
        #expect(CalendarDay("2026-03-12")?.description == "2026-03-12")
        #expect(CalendarDay("2028-02-29") != nil)  // a leap day
        #expect(CalendarDay("2027-02-29") == nil)
        for bad in ["2026-3-12", "2026-13-01", "2026-03-32", "26-03-12", "2026-03-12T00:00", "", "2026/03/12"] {
            #expect(CalendarDay(bad) == nil, "\(bad)")
        }
    }

    @Test func arithmeticCrossesYearsAndLeapDays() {
        #expect(day("2026-01-01").adding(days: 76) == day("2026-03-18"))
        #expect(day("2027-12-20").adding(days: 76) == day("2028-03-05"))
        #expect(day("2028-02-20").adding(days: 16) == day("2028-03-07"))
        #expect(day("2026-03-11").days(until: day("2026-03-18")) == 7)
        #expect(day("2026-03-18").days(until: day("2026-03-11")) == -7)
    }

    @Test func theLocalDayIsNotTheUTCDay() {
        let instant = Date(timeIntervalSince1970: 1_773_286_200)  // 2026-03-12T03:30:00Z
        #expect(CalendarDay(instant, in: TimeZone(identifier: "UTC")!) == day("2026-03-12"))
        #expect(CalendarDay(instant, in: TimeZone(identifier: "America/New_York")!) == day("2026-03-11"))
        #expect(CalendarDay(instant, in: TimeZone(identifier: "Asia/Tokyo")!) == day("2026-03-12"))
        #expect(CalendarDay(instant, in: TimeZone(identifier: "Pacific/Kiritimati")!) == day("2026-03-12"))
    }

    @Test func aDaylightSavingNightStillHasOneDayChange() {
        // New York springs forward on 2026-03-08: 06:59Z is 01:59 EST, 07:00Z is 03:00 EDT.
        let ny = TimeZone(identifier: "America/New_York")!
        let before = Date(timeIntervalSince1970: 1_772_953_140)  // 2026-03-08T06:59:00Z
        let after = Date(timeIntervalSince1970: 1_772_953_200)
        #expect(CalendarDay(before, in: ny) == day("2026-03-08"))
        #expect(CalendarDay(after, in: ny) == day("2026-03-08"))
        #expect(CalendarDay(Date(timeIntervalSince1970: 1_772_953_200 + 21 * 3600), in: ny) == day("2026-03-09"))
    }

    @Test func roundTripsAsText() throws {
        let data = try JSONEncoder().encode(day("2026-03-12"))
        #expect(String(decoding: data, as: UTF8.self) == "\"2026-03-12\"")
        #expect(try JSONDecoder().decode(CalendarDay.self, from: data) == day("2026-03-12"))
    }
}

// MARK: Store

@MainActor
@Suite("Refill store")
struct RefillStoreTests {
    @Test func theClientsLocalDateIsWhatIsSent() async {
        let source = FakeRefillSource()
        // 2026-03-12T03:30Z: still the 11th in New York.
        let instant = Date(timeIntervalSince1970: 1_773_286_200)
        let s = store(source, now: { instant }, zone: TimeZone(identifier: "America/New_York")!)
        await s.refresh()
        #expect(source.asOfSeen == [day("2026-03-11")])
    }

    @Test func statusFlipsAtLocalMidnightNotUTCMidnight() async {
        let source = FakeRefillSource()
        source.refillsFor = { [serverItem(reorder: "2026-03-18", asOf: $0)] }  // lead 7: approaching from 03-11
        let clock = Clock(Date(timeIntervalSince1970: 1_773_286_200))  // 03-12T03:30Z = 03-11 23:30 in New York
        let ny = TimeZone(identifier: "America/New_York")!
        let s = store(source, now: { clock.now }, zone: ny)
        await s.refresh()
        #expect(s.items.first?.status == .approaching)  // 03-11 is the warning date
        clock.now = Date(timeIntervalSince1970: 1_773_286_200 - 24 * 3600)  // 03-10 23:30 in New York
        await s.refresh()
        #expect(s.items.first?.status == .ok)  // the day before the warning date
        #expect(source.asOfSeen == [day("2026-03-11"), day("2026-03-10")])
    }

    @Test(arguments: [
        ("2026-03-09", RefillStatus.ok), ("2026-03-10", .ok), ("2026-03-11", .approaching),
        ("2026-03-17", .approaching), ("2026-03-18", .due), ("2026-03-21", .due),
    ])
    func approachingAndDueBoundaries(local: String, expected: RefillStatus) async {
        let source = FakeRefillSource()
        source.refillsFor = { [serverItem(reorder: "2026-03-18", asOf: $0)] }
        let noon = Date(timeIntervalSince1970: 1_773_316_800 + Double(day("2026-03-12").days(until: day(local))) * 86_400)  // 12:00Z
        let s = store(source, now: { noon })
        await s.refresh()
        #expect(s.items.first?.status == expected)
    }

    @Test func countdownWordsFollowTheSameArithmetic() {
        func words(_ asOf: String) -> String? { serverItem(reorder: "2026-03-18", asOf: day(asOf)).countdown }
        #expect(words("2026-03-17") == "Estimated reorder date in 1 day")
        #expect(words("2026-03-11") == "Estimated reorder date in 7 days")
        #expect(words("2026-03-18") == "Estimated reorder date is today")
        #expect(words("2026-03-21") == "Estimated reorder date was 3 days ago")
    }

    @Test func provenanceIsStatedForEveryKindOfDate() {
        #expect(RefillDateSource.explicit.provenance.contains("entered"))
        #expect(RefillDateSource.fixedInterval.provenance.contains("rule"))
        #expect(RefillDateSource.fallback.provenance.contains("general rule"))
        #expect(RefillDateSource(rawValue: "rule:days_before_end") == .daysBeforeEnd)
        #expect(RefillUnknownReason.resultNotAfterFill.explanation.contains("Set a date"))
    }

    // MARK: Notifications

    @Test func aRaisedNoticePostsOnceAndNeverAgainAcrossRetriesAndRelaunch() async {
        let source = FakeRefillSource()
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        let center = FakeNotificationCenter()
        let state = InMemoryRefillStateStore()
        let s = store(source, center, state: state)
        await s.refresh()
        await s.refresh()
        #expect(center.posts.map(\.id) == ["12:due:2026-03-18"])

        // A relaunch: a new store over the same persisted state.
        let again = store(source, center, state: state)
        await again.refresh()
        #expect(center.posts.count == 1)
    }

    @Test func noNotificationTextNamesAnything() async {
        let source = FakeRefillSource()
        source.noticesFor = { _ in [notice(12, .approaching, "2026-03-18"), notice(13, .due, "2026-03-01")] }
        let center = FakeNotificationCenter()
        await store(source, center).refresh()
        #expect(center.posts.count == 2)
        for post in center.posts {
            #expect(!post.title.contains("Examplepril") && !post.body.contains("Examplepril"))
            #expect(!post.body.contains("2026"))  // not even a date
            #expect(!post.body.lowercased().contains("take") && !post.body.lowercased().contains("eligible"))
        }
    }

    @Test func aCorrectedDateIsANewNoticeAndTheOldOneIsTakenDown() async {
        let source = FakeRefillSource()
        let center = FakeNotificationCenter()
        let s = store(source, center)
        source.noticesFor = { _ in [notice(12, .approaching, "2026-03-18")] }
        await s.refresh()
        source.noticesFor = { _ in [notice(12, .approaching, "2026-03-25")] }
        await s.refresh()
        #expect(center.posts.map(\.id) == ["12:approaching:2026-03-18", "12:approaching:2026-03-25"])
        #expect(center.removed.contains("12:approaching:2026-03-18"))
    }

    @Test func aCorrectedFillShowsWhatTheDateChangedFrom() async {
        let source = FakeRefillSource()
        let s = store(source)
        source.refillsFor = { [serverItem(reorder: "2026-03-18", asOf: $0)] }
        await s.refresh()
        #expect(s.items.first?.correctedFrom == nil)
        source.refillsFor = { [serverItem(reorder: "2026-03-25", asOf: $0)] }
        await s.refresh()
        #expect(s.items.first?.correctedFrom == day("2026-03-18"))
    }

    @Test func nothingIsPostedWithoutPermissionAndItCatchesUpWhenGranted() async {
        let source = FakeRefillSource()
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        let center = FakeNotificationCenter()
        center.allowed = false
        let s = store(source, center)
        await s.refresh()
        #expect(center.posts.isEmpty)
        #expect(s.notificationsAllowed == false)
        center.allowed = true
        await s.refresh()
        #expect(center.posts.count == 1)
    }

    @Test func anOrderOrAcknowledgementElsewhereTakesTheNotificationDown() async {
        let source = FakeRefillSource()
        let center = FakeNotificationCenter()
        let s = store(source, center)
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        await s.refresh()
        source.noticesFor = { _ in [] }  // an open order raises none
        await s.refresh()
        #expect(center.removed.contains("12:due:2026-03-18"))
        // And if the order is cancelled and the same notice returns, it is not posted twice.
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        await s.refresh()
        #expect(center.posts.count == 1)
    }

    // MARK: Acknowledgement

    @Test func anAcknowledgementIsRetriedUntilTheServerConfirmsAndNeverRepostsMeanwhile() async {
        let source = FakeRefillSource()
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        source.ackError = .transportFailed(underlying: URLError(.notConnectedToInternet))
        let center = FakeNotificationCenter()
        let s = store(source, center)
        await s.refresh()
        await s.acknowledge(noticeKey: "12:due:2026-03-18")
        #expect(s.notices.isEmpty)  // gone from the screen at once
        #expect(center.removed.contains("12:due:2026-03-18"))

        await s.refresh()  // the server still lists it, and the ack is retried
        #expect(source.acks.count == 2)
        #expect(s.notices.isEmpty)
        #expect(center.posts.count == 1)

        source.ackError = nil
        await s.refresh()
        #expect(source.acks.count == 3)
        source.noticesFor = { _ in [] }
        await s.refresh()
        #expect(source.acks.count == 3)  // confirmed; nothing left to send
    }

    @Test func aKeyTheServerNoLongerKnowsEndsTheRetry() async {
        let source = FakeRefillSource()
        source.ackError = .notFound
        let s = store(source)
        await s.acknowledge(noticeKey: "12:due:2026-03-18")
        await s.refresh()
        await s.refresh()
        #expect(source.acks.count == 1)
    }

    // MARK: Revocation

    @Test func aRefusedCallerLosesEverythingPrivate() async {
        let source = FakeRefillSource()
        source.refillsFor = { [serverItem(reorder: "2026-03-18", asOf: $0)] }
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        let center = FakeNotificationCenter()
        let state = InMemoryRefillStateStore()
        let s = store(source, center, state: state)
        await s.refresh()
        #expect(s.items.count == 1)

        source.readError = .forbidden
        await s.refresh()
        #expect(s.items.isEmpty && s.notices.isEmpty)
        #expect(s.accessLost)
        #expect(center.removedAll == 1)
        #expect(await state.isEmpty)
        #expect(s.state.error == .forbidden)
    }

    @Test func aRevokedKeyOnTheCapabilitiesCallDoesTheSame() async {
        let source = FakeRefillSource()
        source.capabilitiesError = .unauthorized
        let center = FakeNotificationCenter()
        let s = store(source, center)
        await s.refresh()
        #expect(center.removedAll == 1)
        #expect(s.state.error == .unauthorized)
    }

    @Test func aPrescriptionThatDisappearsLosesItsNotifications() async {
        let source = FakeRefillSource()
        source.refillsFor = { [serverItem(reorder: "2026-03-18", asOf: $0, recipe: 12), serverItem(reorder: "2026-03-18", asOf: $0, recipe: 13)] }
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18"), notice(13, .due, "2026-03-18")] }
        let center = FakeNotificationCenter()
        let s = store(source, center)
        await s.refresh()
        source.refillsFor = { [serverItem(reorder: "2026-03-18", asOf: $0, recipe: 12)] }  // a share was revoked
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        await s.refresh()
        #expect(center.removed.contains("13:due:2026-03-18"))
        #expect(s.items.map(\.recipeID) == [12])
    }

    @Test func signingOutErasesState() async {
        let source = FakeRefillSource()
        source.noticesFor = { _ in [notice(12, .due, "2026-03-18")] }
        let center = FakeNotificationCenter()
        let state = InMemoryRefillStateStore()
        let s = store(source, center, state: state)
        await s.refresh()
        await s.revoke()
        #expect(center.removedAll == 1)
        #expect(await state.isEmpty)
        #expect(s.items.isEmpty)
    }

    // MARK: Gating

    @Test func theScreenIsGatedOnFeaturesNotVersions() async {
        let source = FakeRefillSource()
        source.features = ["refill"]
        let s = store(source)
        await s.refresh()
        #expect(s.availability == .unavailable(.missingFeatures(["refill_notices"])))
        #expect(source.asOfSeen.isEmpty)  // nothing was read

        let older = FakeRefillSource()
        older.capabilitiesError = .notFound
        let o = store(older)
        await o.refresh()
        #expect(o.availability == .unavailable(.olderServer))
        #expect(o.state.error == nil)
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

// MARK: Wire

@Suite("Refill wire")
struct RefillWireTests {
    private func service(_ json: String, status: Int = 200) -> (VictualRefillService, StubTransport) {
        let transport = StubTransport(status: status, json: json)
        return (VictualRefillService(client: .stubbed(transport)), transport)
    }

    private let list = """
        {"as_of":"2026-03-12","as_of_source":"client","refills":[
          {"recipe_id":12,"recipe_name":"X","as_of":"2026-03-12","as_of_source":"client","status":"approaching","days_overdue":null,
           "current_fill":{"id":4,"filled_on":"2026-01-01","supplied_days":90},
           "estimate":{"reorder_date":"2026-03-18","warning_date":"2026-03-11","source":"fallback","lead_days":7,"reason":null},
           "open_order":null},
          {"recipe_id":13,"recipe_name":"Y","as_of":"2026-03-12","as_of_source":"server_utc","status":"unknown",
           "current_fill":null,"estimate":{"reorder_date":null,"warning_date":null,"source":null,"lead_days":7,"reason":"no_fill"},
           "open_order":{"id":2,"ordered_on":"2026-03-10","age_days":2}}]}
        """

    @Test func theLocalDateGoesOutAsAsOfAndTheStateKeepsItsFill() async throws {
        let (service, transport) = service(list)
        let items = try await service.refills(asOf: day("2026-03-12"))
        #expect(transport.recorder.requests[0].url.query == "as_of=2026-03-12")
        #expect(items[0].filledOn == day("2026-01-01"))  // the generated type would have dropped this
        #expect(items[0].suppliedDays == 90)
        #expect(items[0].source == .fallback)
        #expect(items[0].warningDate == day("2026-03-11"))
        #expect(items[1].unknownReason == .noFill)
        #expect(items[1].asOfSource == .serverUTC)
        #expect(items[1].openOrder?.ageDays == 2)
    }

    @Test func noticesDecodeAndAMalformedKeyIsRefused() async throws {
        let good = #"{"as_of":"2026-03-12","notices":[{"key":"12:due:2026-03-18","kind":"due","recipe_id":12,"recipe_name":"X","reorder_date":"2026-03-18","warning_date":"2026-03-11","days_overdue":0,"source":"rule:fixed_interval","text":"t"}]}"#
        let (service, _) = service(good)
        let notices = try await service.notices(asOf: day("2026-03-18"))
        #expect(notices.map(\.key) == ["12:due:2026-03-18"])
        #expect(notices[0].source == .fixedInterval)

        let bad = #"{"notices":[{"key":"not-a-key","kind":"due","recipe_id":12,"reorder_date":"2026-03-18","source":"fallback"}]}"#
        let (other, _) = self.service(bad)
        await #expect(throws: VictualError.self) { try await other.notices(asOf: day("2026-03-18")) }
    }

    @Test func anAcknowledgementPostsTheKey() async throws {
        let (service, transport) = service(#"{"notice_key":"12:due:2026-03-18","acknowledged_at":"2026-03-18T12:00:00.000000Z"}"#)
        try await service.acknowledge(noticeKey: "12:due:2026-03-18")
        let sent = transport.recorder.requests[0]
        #expect(sent.request.method == .post)
        #expect(sent.url.path.hasSuffix("/refills/notices/ack"))
        #expect(sent.jsonBody?["notice_key"] as? String == "12:due:2026-03-18")
    }

    @Test func fillsIncludeVoidedOnes() async throws {
        let (service, transport) = service(
            #"{"recipe_id":12,"status":"ok","fills":[{"id":5,"filled_on":"2026-02-01","supplied_days":30,"is_current":true,"voided_at":null},{"id":4,"filled_on":"2026-01-01","supplied_days":90,"is_current":false,"voided_at":"2026-02-01T10:00:00.000000Z"}]}"#)
        let fills = try await service.fills(recipeID: 12, asOf: day("2026-03-12"))
        #expect(fills.map(\.isVoided) == [false, true])
        #expect(fills.first?.isCurrent == true)
        #expect(transport.recorder.requests[0].url.path.hasSuffix("/consumption/recipes/12/refill"))
    }

    @Test func aRefusalIsAnError() async {
        let (service, _) = service(#"{"error_message":"bad as_of"}"#, status: 422)
        await #expect(throws: VictualError.badRequest(message: "bad as_of")) { try await service.refills(asOf: day("2026-03-12")) }
    }

    @Test func notificationTextIsFixed() {
        #expect(RefillNotificationContent.body(for: .approaching) == "A refill is coming up.")
        #expect(RefillNotificationContent.body(for: .due) == "A refill reorder date has arrived.")
    }
}
