import Foundation
import Testing
import VictualCore
@testable import VictualHealth

@Suite("Dose sync engine")
struct DoseSyncEngineTests {
    typealias F = Fixtures

    // MARK: Field mapping (ADR sequences 1, 2, 5)

    @Test func takenDoseIsSentWithTheMappingTable() async throws {
        let event = F.dose("D1", quantity: 2, unit: "tablet", at: F.t0 + 3600)
        let source = ScriptedSource([F.batch([event])])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull()
        try await engine.drain()

        let put = try #require(submitter.puts.first)
        #expect(submitter.calls.count == 1)
        #expect(put.status == .taken)
        #expect(put.medicationRef == "hk:med:42")
        #expect(put.quantity == 2)
        #expect(put.unitLabel == "tablet")
        #expect(put.locationID == nil)  // fixed mapping: the server decides
        #expect(put.replaces == nil)
        // The dose's own start, in the device offset, not the time of sending.
        #expect(put.occurredAt?.date == F.t0 + 3600)
        #expect(put.occurredAt?.text.hasSuffix("-04:00") == true)
        #expect(put.sourceUpdatedAt?.date == F.t0)
    }

    @Test func explicitMappingSendsLocation() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1")])])
        let submitter = FakeSubmitter()
        let engine = F.engine(
            source: source, submitter: submitter,
            mappings: [F.mapping(location: .init(mode: .explicit, locationID: 11))])
        try await engine.pull()
        try await engine.drain()
        #expect(submitter.puts.first?.locationID == 11)
    }

    @Test func lateDoseCarriesItsOwnStartDate() async throws {
        let late = F.dose("D1", at: F.t0 - 2 * 3600)  // logged now, taken two hours ago
        let source = ScriptedSource([F.batch([late])])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter, now: { F.t0 + 86_400 })
        try await engine.pull()
        try await engine.drain()
        #expect(submitter.puts.first?.occurredAt?.date == F.t0 - 2 * 3600)
        #expect(submitter.puts.first?.sourceUpdatedAt?.date == F.t0 + 86_400)
    }

    @Test func nilQuantityIsOmittedFromTheBody() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1", quantity: nil)])])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull()
        try await engine.drain()
        guard case .put(_, let body) = try #require(submitter.calls.first) else { return }
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["quantity"] == nil)
        #expect(object["unit_label"] as? String == "tablet")
    }

    // MARK: Dropped locally (ADR sequences 4, 9)

    @Test func doseBeforeEffectiveFromIsNeverQueued() async throws {
        let old = F.dose("D1", at: F.t0 - 10 * 86_400)
        let engine = F.engine(source: ScriptedSource([F.batch([old])]))
        try await engine.pull()
        #expect(try await engine.queue().outbox.isEmpty)
        #expect(try await engine.queue().ledger.isEmpty)
    }

    @Test(arguments: [DoseLogStatus.skipped, .snoozed, .notInteracted, .notificationNotSent, .notLogged])
    func nonTakenForADoseNeverSentIsDropped(status: DoseLogStatus) async throws {
        let source = ScriptedSource([F.batch([F.dose("D1", status: status)])])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        let report = try await engine.pull()
        try await engine.drain()
        #expect(submitter.calls.isEmpty)
        #expect(try await engine.queue().outbox.isEmpty)
        #expect(report.queued == 0)
    }

    @Test func unmappedMedicationQueuesNothingAndIsReported() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1", ref: "hk:med:99")])])
        let engine = F.engine(source: source)
        let report = try await engine.pull()
        #expect(report.needsMapping == ["hk:med:99"])
        #expect(try await engine.queue().outbox.isEmpty)
    }

    // MARK: Later status for a sent dose (ADR sequence 8)

    @Test(arguments: [
        (DoseLogStatus.skipped, ConsumptionStatus.skipped),
        (.snoozed, .scheduled),
        (.notInteracted, .unanswered),
    ])
    func laterStatusOnTheSameSampleIsSentForTheSameId(status: DoseLogStatus, wire: ConsumptionStatus) async throws {
        let source = ScriptedSource([F.batch([F.dose("D1")]), F.batch([F.dose("D1", status: status)], anchor: "a2")])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.drain()
        try await engine.pull(); try await engine.drain()
        #expect(submitter.puts.map(\.status) == [.taken, wire])
        #expect(submitter.calls.count == 2)
    }

    @Test func notLoggedSampleGoesToTheDoseItUndoes() async throws {
        let scheduled = F.t0 + 7200
        let source = ScriptedSource([
            F.batch([F.dose("D1", scheduled: scheduled, type: .schedule)]),
            F.batch([F.dose("U9", status: .notLogged, scheduled: scheduled, type: .schedule)], anchor: "a2"),
        ])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.drain()
        try await engine.pull(); try await engine.drain()

        // PUT not_logged on the *sent* id, with no DELETE: the new sample's own uuid is unknown to the server.
        guard case .put(let id, _) = try #require(submitter.calls.last) else { return }
        #expect(id == "D1")
        #expect(submitter.puts.last?.status == .notLogged)
        #expect(submitter.deletes.isEmpty)
    }

    @Test func notLoggedThatMatchesNothingOrSeveralSendsNothing() async throws {
        let source = ScriptedSource([
            F.batch([F.dose("D1", at: F.t0 + 100), F.dose("D2", at: F.t0 + 100)]),
            F.batch([F.dose("U9", status: .notLogged, at: F.t0 + 100)], anchor: "a2"),
            F.batch([F.dose("U10", status: .notLogged, at: F.t0 + 999)], anchor: "a3"),
        ])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.drain()
        let ambiguous = try await engine.pull()
        let none = try await engine.pull()
        try await engine.drain()
        #expect(ambiguous.unmatchedUndos == 1)
        #expect(none.unmatchedUndos == 1)
        #expect(submitter.calls.count == 2)  // only the two takens
    }

    // MARK: replaces heuristic (ADR 6, 7)

    private func editBatches(
        oldType: DoseScheduleType = .schedule, newType: DoseScheduleType = .schedule,
        oldScheduled: Date? = F.t0 + 7200, newScheduled: Date? = F.t0 + 7200,
        newRef: String = "hk:med:42", inSameBatch: Bool = true
    ) -> [DoseEventBatch] {
        let old = F.dose("OLD", scheduled: oldScheduled, type: oldType)
        let new = F.dose("NEW", ref: newRef, quantity: 2, scheduled: newScheduled, type: newType)
        if inSameBatch {
            return [F.batch([old]), F.batch([new], deleted: ["OLD"], anchor: "a2")]
        }
        return [F.batch([old]), F.batch(deleted: ["OLD"], anchor: "a2"), F.batch([new], anchor: "a3")]
    }

    private func runEdit(_ batches: [DoseEventBatch], mappings: [Mapping] = [F.mapping()]) async throws -> FakeSubmitter {
        let submitter = FakeSubmitter()
        let engine = F.engine(source: ScriptedSource(batches), submitter: submitter, mappings: mappings)
        for _ in batches { try await engine.pull() }
        try await engine.drain()
        return submitter
    }

    @Test func scheduledEditInOneBatchSendsReplaces() async throws {
        let submitter = try await runEdit(editBatches())
        let new = try #require(submitter.puts.last)
        #expect(new.replaces == "OLD")
        #expect(new.quantity == 2)
        #expect(submitter.deletes.isEmpty)  // the new event's `replaces` carries the void
    }

    @Test func asNeededEditNeverSendsReplaces() async throws {
        let submitter = try await runEdit(editBatches(oldType: .asNeeded, newType: .asNeeded))
        #expect(submitter.puts.last?.replaces == nil)
        #expect(submitter.deletes.count == 1)
    }

    @Test func nilScheduledDateNeverSendsReplaces() async throws {
        let submitter = try await runEdit(editBatches(oldScheduled: nil, newScheduled: nil))
        #expect(submitter.puts.last?.replaces == nil)
    }

    @Test func differentScheduledDateOrMedicationNeverSendsReplaces() async throws {
        #expect(try await runEdit(editBatches(newScheduled: F.t0 + 9999)).puts.last?.replaces == nil)
        let other = [F.mapping(), F.mapping("hk:med:43")]
        #expect(try await runEdit(editBatches(newRef: "hk:med:43"), mappings: other).puts.last?.replaces == nil)
    }

    @Test func deleteAndRecreateInSeparateBatchesNeverSendsReplaces() async throws {
        let submitter = try await runEdit(editBatches(inSameBatch: false))
        #expect(submitter.puts.last?.replaces == nil)
        #expect(submitter.deletes.count == 1)
    }

    @Test func twoCandidatesAreAmbiguousAndNotPaired() async throws {
        let s = F.t0 + 7200
        let source = ScriptedSource([
            F.batch([F.dose("O1", scheduled: s, type: .schedule), F.dose("O2", scheduled: s, type: .schedule)]),
            F.batch([F.dose("N1", scheduled: s, type: .schedule), F.dose("N2", scheduled: s, type: .schedule)],
                    deleted: ["O1", "O2"], anchor: "a2"),
        ])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.pull(); try await engine.drain()
        #expect(submitter.puts.compactMap(\.replaces).isEmpty)
        #expect(submitter.deletes.count == 2)
    }

    // MARK: Deletion reasons (ADR 9a, 9b)

    private func deletion(
        availability: [String: MedicationAvailability]
    ) async throws -> (FakeSubmitter, ScriptedSource) {
        let source = ScriptedSource(
            [F.batch([F.dose("D1")]), F.batch(deleted: ["D1"], anchor: "a2")], availability: availability)
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.pull(); try await engine.drain()
        return (submitter, source)
    }

    @Test func bareDeletionOfActiveMedicationOmitsTheReason() async throws {
        let (submitter, _) = try await deletion(availability: ["hk:med:42": .active])
        #expect(submitter.deletes.count == 1)
        #expect(submitter.deletes[0].reason == nil)
    }

    @Test func deletionOfARevokedMedicationSaysAccessRevoked() async throws {
        let (submitter, _) = try await deletion(availability: [:])
        #expect(submitter.deletes[0].reason == .accessRevoked)
    }

    @Test func deletionOfAnArchivedMedicationSaysMedicationArchived() async throws {
        let (submitter, _) = try await deletion(availability: ["hk:med:42": .archived])
        #expect(submitter.deletes[0].reason == .medicationArchived)
    }

    @Test func neverSendsEnteredInErrorOrHistoryClearedOrUnknown() async throws {
        let sendable: Set<DeletionReason?> = [nil, .accessRevoked, .medicationArchived]
        for availability: [String: MedicationAvailability] in [[:], ["hk:med:42": .active], ["hk:med:42": .archived]] {
            let (submitter, _) = try await deletion(availability: availability)
            for call in submitter.deletes { #expect(sendable.contains(call.reason)) }
        }
        // And the planner has no path to them at all.
        let entry = LedgerEntry(
            id: "x", medicationRef: "m", occurredAt: F.t0, unit: "u", scheduleType: .asNeeded, state: .taken)
        for availability: [String: MedicationAvailability]? in [nil, [:], ["m": .active], ["m": .archived]] {
            #expect(sendable.contains(DoseSyncPlanner.deletionReason(for: entry, availability: availability)))
        }
    }

    @Test func deletionOfAnUnknownIdDoesNothing() async throws {
        let source = ScriptedSource([F.batch(deleted: ["never-sent"])])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.drain()
        #expect(submitter.calls.isEmpty)
        #expect(source.availabilityQueries == 0)  // no evidence needed, so none asked for
    }

    @Test func revokedDeletionsAreReportedSoTheMappingCanBeMarkedUnavailable() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1")]), F.batch(deleted: ["D1"], anchor: "a2")], availability: [:])
        let engine = F.engine(source: source)
        try await engine.pull()
        let report = try await engine.pull()
        #expect(report.revoked == ["hk:med:42"])
    }

    @Test func deleteOfAnEventTheServerNeverHadIsDropped() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1")]), F.batch(deleted: ["D1"], anchor: "a2")], availability: ["hk:med:42": .active])
        let submitter = FakeSubmitter()
        submitter.failWhen { if case .delete = $0 { .notFound } else { nil } }
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.pull()
        let report = try await engine.drain()
        #expect(report.held == 0)
        #expect(try await engine.queue().outbox.isEmpty)
    }

    // MARK: Outbox, anchor, replay (ADR 3, 9e)

    @Test func queueIsWrittenBeforeTheAnchorAdvances() async throws {
        let storage = MemoryStateStore()
        let engine = F.engine(source: ScriptedSource([F.batch([F.dose("D1")])]), storage: storage)
        try await engine.pull()
        let log = await storage.writeLog
        #expect(log == ["queue", "anchor"])
    }

    @Test func crashBeforeTheAnchorAdvancesReplaysWithoutDuplicatingOrChangingBytes() async throws {
        let storage = MemoryStateStore()
        let batch = F.batch([F.dose("D1")])
        let source = ScriptedSource([batch, batch])
        let submitter = FakeSubmitter()
        let clock = Clock(F.t0)
        let engine = F.engine(source: source, submitter: submitter, storage: storage, now: { clock.now })

        await storage.setFailNextAnchorWrite(true)
        await #expect(throws: MemoryStateStore.Crash.self) { try await engine.pull() }
        #expect(try await engine.queue().outbox.count == 1)  // the outbox survived the crash

        clock.now = F.t0 + 600  // the replay happens later
        try await engine.pull()
        #expect(source.anchorsSeen.count == 2)
        #expect(source.anchorsSeen[1] == nil)  // the anchor never advanced, so the batch replays
        #expect(try await engine.queue().outbox.count == 1)

        try await engine.drain()
        let put = try #require(submitter.puts.first)
        #expect(put.sourceUpdatedAt?.date == F.t0)  // the first observation time is the one that is kept
        #expect(submitter.calls.count == 1)
    }

    @Test func crashAfterSendingBeforeRemovalResendsIdenticalBytes() async throws {
        let storage = MemoryStateStore()
        let submitter = FakeSubmitter()
        let clock = Clock(F.t0)
        let engine = F.engine(source: ScriptedSource([F.batch([F.dose("D1")])]), submitter: submitter, storage: storage, now: { clock.now })
        try await engine.pull()
        // The server got the request but the response was lost: a transport failure after the send.
        submitter.failWhen { _ in .transportFailed(underlying: URLError(.networkConnectionLost)) }
        await #expect(throws: VictualError.self) { try await engine.drain() }
        submitter.clearFailures()
        clock.now = F.t0 + 3600
        try await engine.drain()
        let bodies = submitter.calls.compactMap { call -> Data? in if case .put(_, let b) = call { b } else { nil } }
        #expect(bodies.count == 2)
        #expect(bodies[0] == bodies[1])
    }

    @Test func redeliveredBatchAfterSendingIsANoOp() async throws {
        let batch = F.batch([F.dose("D1")])
        let source = ScriptedSource([batch, batch])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.drain()
        try await engine.pull(); try await engine.drain()
        #expect(submitter.calls.count == 1)
    }

    @Test func undoneEventIsNeverRebookedByReplay() async throws {
        let batch = F.batch([F.dose("D1")])
        let source = ScriptedSource([batch, batch, batch])
        let submitter = FakeSubmitter()
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull(); try await engine.drain()
        submitter.respond(to: "D1", with: ConsumptionEvent(sourceEventID: "D1", state: .undone))
        for _ in 0..<2 { try await engine.pull(); try await engine.drain() }
        #expect(submitter.calls.count == 1)
    }

    @Test func outboxSendsInOrderAndStopsAtARetryableFailure() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1"), F.dose("D2"), F.dose("D3")])])
        let submitter = FakeSubmitter()
        submitter.failWhen { if case .put(let id, _) = $0, id == "D2" { .serverError(statusCode: 503, message: nil) } else { nil } }
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull()
        await #expect(throws: VictualError.self) { try await engine.drain() }
        #expect(try await engine.queue().outbox.map(\.eventID) == ["D2", "D3"])

        submitter.clearFailures()
        try await engine.drain()
        let sent = submitter.calls.compactMap { call -> String? in if case .put(let id, _) = call { id } else { nil } }
        #expect(sent == ["D1", "D2", "D2", "D3"])
        #expect(try await engine.queue().outbox.isEmpty)
    }

    @Test func rejectedRecordIsHeldAndDoesNotBlockTheOthers() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1"), F.dose("D2")])])
        let submitter = FakeSubmitter()
        submitter.failWhen { if case .put(let id, _) = $0, id == "D1" { .badRequest(message: "nope") } else { nil } }
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull()
        let report = try await engine.drain()
        #expect(report.sent == 1)
        #expect(report.held == 1)
        let remaining = try await engine.queue().outbox
        #expect(remaining.map(\.eventID) == ["D1"])
        #expect(remaining[0].held)
        // A held record is not retried on the next drain.
        _ = try await engine.drain()
        #expect(submitter.calls.count == 2)
    }

    // MARK: Anchor keys (ADR 17)

    @Test func anchorsDoNotCrossServersAccountsOrMappingSets() async throws {
        let storage = MemoryStateStore()
        let first = F.engine(source: ScriptedSource([F.batch(anchor: "mine")]), storage: storage)
        try await first.pull()

        for (server, account, mappings) in [
            ("https://other.example", "me", [F.mapping()]),
            ("https://v.example", "someone-else", [F.mapping()]),
            ("https://v.example", "me", [F.mapping(location: .init(mode: .fixed, locationID: 10))]),
        ] {
            let source = ScriptedSource([F.batch(anchor: "x")])
            let engine = F.engine(source: source, storage: storage, account: account, server: server, mappings: mappings)
            try await engine.pull()
            #expect(source.anchorsSeen == [nil])
        }

        let same = ScriptedSource([])
        try await F.engine(source: same, storage: storage).pull()
        #expect(same.anchorsSeen == [Data("mine".utf8)])
    }

    @Test func reMappingKeepsTheQueueButRestartsTheRead() async throws {
        let storage = MemoryStateStore()
        let first = F.engine(source: ScriptedSource([F.batch([F.dose("D1")])]), storage: storage)
        try await first.pull()
        let source = ScriptedSource([])
        let remapped = F.engine(source: source, storage: storage, mappings: [F.mapping(location: .init(mode: .fixed, locationID: 10))])
        try await remapped.pull()
        #expect(source.anchorsSeen == [nil])
        #expect(try await remapped.queue().outbox.map(\.eventID) == ["D1"])
    }

    // MARK: 401

    @Test func unauthorizedStopsTheDrainAndKeepsTheQueue() async throws {
        let source = ScriptedSource([F.batch([F.dose("D1"), F.dose("D2")])])
        let submitter = FakeSubmitter()
        submitter.failWhen { _ in .unauthorized }
        let engine = F.engine(source: source, submitter: submitter)
        try await engine.pull()
        await #expect(throws: VictualError.self) { try await engine.drain() }
        #expect(submitter.calls.count == 1)
        #expect(try await engine.queue().outbox.count == 2)
    }
}

/// A clock a test can move.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}
