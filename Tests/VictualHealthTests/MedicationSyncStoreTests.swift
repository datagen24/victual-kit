import Foundation
import Testing
import VictualCore
@testable import VictualHealth

@MainActor
@Suite("Medication sync store")
struct MedicationSyncStoreTests {
    typealias F = Fixtures

    func makeStore(
        _ batches: [DoseEventBatch] = [], submitter: FakeSubmitter = FakeSubmitter(),
        features: Set<String> = [], availability: [String: MedicationAvailability] = ["hk:med:42": .active]
    ) -> (MedicationSyncStore, ScriptedSource, FakeSubmitter) {
        let source = ScriptedSource(batches, availability: availability)
        let store = MedicationSyncStore(
            source: source, submitter: submitter, storage: MemoryStateStore(),
            server: "https://v.example", account: "me", mappings: MappingSet([F.mapping()]),
            requiredFeatures: features, now: { F.t0 }, zone: { F.zone })
        return (store, source, submitter)
    }

    // MARK: Capabilities (feature visibility)

    @Test func olderServerHidesMedicationsWithAReason() async {
        let (store, source, submitter) = makeStore([F.batch([F.dose("D1")])])
        submitter.setCapabilities(.failure(.notFound))
        await store.sync()
        #expect(store.availability == .unavailable(.olderServer))
        #expect(source.anchorsSeen.isEmpty)  // nothing was read, let alone sent
        #expect(submitter.calls.isEmpty)
        #expect(store.state.error == nil)  // an older server is not a failure
    }

    @Test func missingFeatureNamesWhatIsMissing() async {
        let (store, _, submitter) = makeStore(features: ["external_events", "bulk_resolve"])
        submitter.setCapabilities(.success(.init(contractVersion: 1, features: ["external_events"])))
        await store.checkAvailability()
        #expect(store.availability == .unavailable(.missingFeatures(["bulk_resolve"])))
    }

    @Test func capabilitiesOnAnOlderServerLetsASyncRun() async {
        let (store, _, submitter) = makeStore([F.batch([F.dose("D1")])], features: ["external_events"])
        submitter.setCapabilities(.success(.init(contractVersion: 1, features: ["external_events", "x"])))
        await store.sync()
        #expect(store.availability == .available)
        #expect(submitter.calls.count == 1)
        guard case .synced = store.state else { Issue.record("expected synced, got \(store.state)"); return }
        #expect(store.lastSynced == F.t0)
    }

    // MARK: 401

    @Test func lapsedKeySurfacesAsAFailureAndKeepsTheQueue() async throws {
        let (store, source, submitter) = makeStore([F.batch([F.dose("D1")])])
        submitter.failWhen { if case .put = $0 { .unauthorized } else { nil } }
        await store.sync()
        guard case .failed(let error) = store.state, case .unauthorized = error else {
            Issue.record("expected failed(.unauthorized), got \(store.state)"); return
        }
        #expect(store.lastSynced == nil)

        // The key is replaced; the next sync sends what was waiting, without re-reading Health.
        submitter.clearFailures()
        source.enqueue(F.batch(anchor: "a2"))
        await store.sync()
        guard case .synced = store.state else { Issue.record("expected synced"); return }
        #expect(submitter.puts.count == 2)  // the failed attempt and the retry
        #expect(await store.serverState(for: "D1") == .booked)
    }

    // MARK: Review rows

    @Test func unmappedMedicationShowsNeedsMapping() async {
        let (store, _, _) = makeStore([F.batch([F.dose("D1", ref: "hk:med:99")])])
        await store.sync()
        #expect(store.reviewRows == [.needsMapping(medicationRef: "hk:med:99")])
        #expect(store.needsMapping == ["hk:med:99"])
    }

    @Test func serverNeedsMappingShowsTheSameRow() async {
        let submitter = FakeSubmitter()
        submitter.respond(to: "D1", with: ConsumptionEvent(sourceEventID: "D1", state: .needsMapping))
        let (store, _, _) = makeStore([F.batch([F.dose("D1")])], submitter: submitter)
        await store.sync()
        #expect(store.reviewRows == [.needsMapping(medicationRef: "hk:med:42")])
    }

    @Test func aBurstOfBareDeletionsIsOneRow() async throws {
        let ids = (1...5).map { "D\($0)" }
        let submitter = FakeSubmitter()
        for id in ids {
            submitter.respond(to: id, with: ConsumptionEvent(sourceEventID: id, state: .needsReview, reason: .sourceDeleted))
        }
        let (store, _, _) = makeStore(
            [F.batch(ids.map { F.dose($0) }), F.batch(deleted: ids, anchor: "a2")], submitter: submitter)
        await store.sync()
        await store.sync()
        #expect(store.reviewRows == [.sourceDeleted(medicationRef: "hk:med:42", eventIDs: ids)])

        await store.resolveDeletions(medicationRef: "hk:med:42", action: .keep)
        let resolved = submitter.calls.filter { if case .resolve(_, .keep) = $0 { true } else { false } }
        #expect(resolved.count == 5)
    }

    @Test func unitUnconfirmedShowsTheExactStringAndApprovalResolvesIt() async {
        let submitter = FakeSubmitter()
        submitter.respond(
            to: "D1",
            with: ConsumptionEvent(sourceEventID: "D1", state: .needsReview, reason: .unitUnconfirmed, unitLabelSeen: "tablet(s)"))
        let (store, _, _) = makeStore([F.batch([F.dose("D1", unit: "tablet(s)")])], submitter: submitter)
        await store.sync()
        #expect(store.reviewRows == [.unitUnconfirmed(eventID: "D1", label: "tablet(s)")])

        submitter.respond(to: "D1", with: ConsumptionEvent(sourceEventID: "D1", state: .booked))
        await store.approveUnit(eventID: "D1")
        #expect(submitter.calls.last == .resolve(id: "D1", action: .approveUnit))
        #expect(store.reviewRows.isEmpty)
    }

    @Test(arguments: [ConsumptionReviewReason.insufficientStock, .ambiguousLocation, .recipeUnavailable, .quantityMissing])
    func otherReasonsAreShownAsTheServerSentThem(reason: ConsumptionReviewReason) async {
        let submitter = FakeSubmitter()
        submitter.respond(to: "D1", with: ConsumptionEvent(sourceEventID: "D1", state: .needsReview, reason: reason))
        let (store, _, _) = makeStore([F.batch([F.dose("D1")])], submitter: submitter)
        await store.sync()
        #expect(store.reviewRows == [.needsReview(eventID: "D1", reason: reason)])
    }

    @Test func possibleDuplicatesAreSurfaced() async {
        let submitter = FakeSubmitter()
        var event = ConsumptionEvent(sourceEventID: "D1", state: .booked)
        event.possibleDuplicates = [.init(transactionID: "tx-9", occurredAt: nil)]
        submitter.respond(to: "D1", with: event)
        let (store, _, _) = makeStore([F.batch([F.dose("D1")])], submitter: submitter)
        await store.sync()
        #expect(store.reviewRows == [.possibleDuplicate(eventID: "D1", transactionIDs: ["tx-9"])])
    }

    @Test func revokedMedicationIsMarkedUnavailable() async {
        let (store, _, _) = makeStore(
            [F.batch([F.dose("D1")]), F.batch(deleted: ["D1"], anchor: "a2")], availability: [:])
        await store.sync()
        await store.sync()
        #expect(store.unavailableMedications == ["hk:med:42"])
    }

    @Test func undoneEventStaysUndoneAcrossSyncs() async {
        let batch = F.batch([F.dose("D1")])
        let submitter = FakeSubmitter()
        submitter.respond(to: "D1", with: ConsumptionEvent(sourceEventID: "D1", state: .undone))
        let (store, _, _) = makeStore([batch, batch, batch], submitter: submitter)
        await store.sync(); await store.sync(); await store.sync()
        #expect(await store.serverState(for: "D1") == .undone)
        #expect(submitter.calls.count == 1)
    }
}
