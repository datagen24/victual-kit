import Foundation
import Testing
import VictualCore
@testable import VictualHealth

private struct ScriptedMedications: HealthMedicationSource {
    var list: [HealthMedication]
    func medications() async throws -> [HealthMedication] { list }
    func requestMedicationAuthorization() async throws {}
}

private func decodeJSON(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Mapping wire types and draft")
struct MappingWireTests {
    private let zone = TimeZone(identifier: "America/New_York")!

    private func product(factor: Double = 1) -> MappingDraft {
        var draft = MappingDraft(effectiveFrom: Date(timeIntervalSince1970: 1_790_000_000))
        draft.productID = 17
        draft.unit = CatalogUnit(id: 1, name: "tablet", factorToStockUnit: factor)
        draft.locationID = 9
        return draft
    }

    @Test func theAdrExampleDecodes() throws {
        let json = """
            {"source_system":"healthkit","medication_ref":"hk:med:42","product_id":17,"quantity_factor":1,
             "unit_labels":[],"default_quantity":null,
             "location":{"mode":"fixed","location_id":9},"effective_from":"2026-10-09T00:00:00-04:00"}
            """
        let mapping = try JSONDecoder().decode(ConsumptionMapping.self, from: Data(json.utf8))
        #expect(mapping.medicationRef == "hk:med:42")
        #expect(mapping.input.productID == 17)
        #expect(mapping.input.defaultQuantity == nil)
        #expect(mapping.input.location == .init(mode: .fixed, locationID: 9))
        #expect(mapping.deviceMapping?.target == .product(17))
    }

    @Test func aProductDraftEncodesTheFragmentsKeys() throws {
        var draft = product(factor: 30)  // a unit other than the stock unit
        draft.unit = CatalogUnit(id: 2, name: "box", factorToStockUnit: 30, isStockUnit: false)
        draft.defaultQuantityText = "1,5"
        let input = try #require(draft.input(in: zone))
        let object = try decodeJSON(JSONEncoder().encode(input))
        #expect(object["product_id"] as? Int == 17)
        #expect(object["recipe_id"] == nil)
        #expect(object["quantity_factor"] as? Double == 1)
        #expect(object["qu_id"] as? Int == 2)
        #expect(object["default_quantity"] as? Double == 1.5)
        #expect((object["location"] as? [String: Any])?["location_id"] as? Int == 9)
        #expect(object["unit_labels"] as? [String] == [])
    }

    @Test func aRecipeDraftSendsNoFactorAndNoProduct() throws {
        var draft = MappingDraft(effectiveFrom: Date())
        draft.targetKind = .recipe
        draft.recipeID = 4
        draft.locationMode = .single
        let input = try #require(draft.input(in: zone))
        #expect(input.recipeID == 4)
        #expect(input.productID == nil)
        #expect(input.quantityFactor == nil)
        #expect(input.location.locationID == nil)
    }

    @Test func eachMissingChoiceIsNamed() {
        var draft = MappingDraft(effectiveFrom: Date())
        #expect(draft.problem == "Choose the Victual product.")
        draft.productID = 1
        #expect(draft.problem == "Choose the unit a dose is counted in.")
        draft.unit = CatalogUnit(id: 1, name: "x", factorToStockUnit: 1)
        #expect(draft.problem == "Choose the organizer to take from.")
        draft.locationMode = .single
        #expect(draft.problem == nil)
        draft.defaultQuantityText = "0"
        #expect(draft.problem == "A default quantity must be a number above zero.")
        draft.defaultQuantityText = ""
        #expect(draft.problem == nil)
        #expect(draft.input() != nil)
    }

    @Test func onlyFixedStoresAnOrganizer() throws {
        // The server refuses a location_id with single or explicit.
        var draft = product()
        draft.locationMode = .explicit
        #expect(try #require(draft.input(in: zone)).location == .init(mode: .explicit, locationID: nil))
        draft.locationMode = .single
        #expect(try #require(draft.input(in: zone)).location.locationID == nil)
        draft.locationMode = .fixed
        draft.locationID = nil
        #expect(draft.problem != nil)
    }

    @Test func theStockUnitIsSentAsNoUnit() throws {
        let object = try decodeJSON(JSONEncoder().encode(try #require(product().input(in: zone))))
        #expect(object["qu_id"] == nil)
    }

    @Test func editingRestoresTheStoredUnit() throws {
        var draft = product()
        draft.unit = CatalogUnit(id: 2, name: "box", factorToStockUnit: 30, isStockUnit: false)
        let stored = ConsumptionMapping(medicationRef: "r", input: try #require(draft.input(in: zone)))
        var again = MappingDraft(editing: stored)
        again.selectStoredUnit(from: [CatalogUnit(id: 1, name: "tablet", factorToStockUnit: 1, isStockUnit: true), CatalogUnit(id: 2, name: "box", factorToStockUnit: 30, isStockUnit: false)])
        #expect(again.unit?.id == 2)
        var stock = MappingDraft(editing: ConsumptionMapping(medicationRef: "r", input: try #require(product().input(in: zone))))
        stock.selectStoredUnit(from: [CatalogUnit(id: 1, name: "tablet", factorToStockUnit: 1, isStockUnit: true)])
        #expect(stock.unit?.id == 1)
    }

    @Test func editingKeepsConfirmedUnitLabels() throws {
        var draft = product()
        draft.unitLabels = ["tablet"]
        let mapping = ConsumptionMapping(medicationRef: "r", input: try #require(draft.input(in: zone)))
        let again = MappingDraft(editing: mapping)
        #expect(again.unitLabels == ["tablet"])
        #expect(again.unit == nil)  // restored later, from the product's unit list
    }
}

@MainActor
@Suite("Medication setup store")
struct MedicationSetupStoreTests {
    typealias F = Fixtures

    private func make(
        _ medications: [HealthMedication], backend: DemoMedicationBackend = DemoMedicationBackend(),
        decisions: InMemorySetupDecisionStore = InMemorySetupDecisionStore()
    ) -> (MedicationSetupStore, MedicationSyncStore, DemoMedicationBackend) {
        let sync = MedicationSyncStore(
            source: ScriptedSource([]), submitter: backend, storage: MemoryStateStore(),
            server: "https://v.example", account: "me", now: { F.t0 }, zone: { F.zone })
        let store = MedicationSetupStore(
            medicationSource: ScriptedMedications(list: medications), mappingService: backend, catalog: backend,
            decisionStore: decisions, sync: sync, server: "https://v.example", account: "me", zone: { F.zone })
        return (store, sync, backend)
    }

    private func draft() -> MappingDraft {
        var draft = MappingDraft(effectiveFrom: F.t0)
        draft.productID = 1
        draft.unit = CatalogUnit(id: 1, name: "piece", factorToStockUnit: 1)
        draft.locationID = 1
        return draft
    }

    @Test func everyItemStartsUnsettledAndNothingIsGuessed() async {
        let (store, _, _) = make([HealthMedication(ref: "a", displayName: "Alpha"), HealthMedication(ref: "b", displayName: "Beta")])
        await store.load()
        #expect(store.items.map(\.status) == [.unsettled, .unsettled])
        #expect(store.unsettled.count == 2)
    }

    @Test func savingAMappingSettlesOnlyThatItem() async throws {
        let (store, _, backend) = make([HealthMedication(ref: "a", displayName: "Alpha"), HealthMedication(ref: "b", displayName: "Beta")])
        await store.load()
        #expect(await store.save(draft(), for: "a"))
        guard case .mapped = store.items[0].status else { Issue.record("a not mapped"); return }
        #expect(store.items[1].status == .unsettled)
        #expect(try await backend.mappings().map(\.medicationRef) == ["a"])
    }

    @Test func aSavedMappingNeverCarriesAName() async throws {
        let (store, _, backend) = make([HealthMedication(ref: "a", displayName: "Examplepril")])
        await store.load()
        _ = await store.save(draft(), for: "a")
        let sent = try JSONEncoder().encode(try await backend.mappings())
        #expect(!String(decoding: sent, as: UTF8.self).contains("Examplepril"))
    }

    @Test func aRefusedSaveKeepsTheItemUnsettledAndSaysWhy() async {
        struct Refusing: ConsumptionMappingService {
            func mappings() async throws -> [ConsumptionMapping] { [] }
            func put(_ input: ConsumptionMappingInput, medicationRef: String) async throws -> ConsumptionMapping { throw VictualError.forbidden }
            func delete(medicationRef: String) async throws {}
        }
        let backend = DemoMedicationBackend()
        let sync = MedicationSyncStore(
            source: ScriptedSource([]), submitter: backend, storage: MemoryStateStore(),
            server: "s", account: "me", now: { F.t0 }, zone: { F.zone })
        let store = MedicationSetupStore(
            medicationSource: ScriptedMedications(list: [HealthMedication(ref: "a", displayName: "Alpha")]),
            mappingService: Refusing(), catalog: backend, decisionStore: InMemorySetupDecisionStore(), sync: sync,
            server: "s", account: "me")
        await store.load()
        #expect(await store.save(draft(), for: "a") == false)
        #expect(store.saveError == .forbidden)
        #expect(store.items[0].status == .unsettled)
    }

    @Test func waitingAndSkippedAreRememberedAndNotUnsettled() async {
        let decisions = InMemorySetupDecisionStore()
        let meds = [HealthMedication(ref: "a", displayName: "A"), HealthMedication(ref: "b", displayName: "B"), HealthMedication(ref: "c", displayName: "C")]
        let (store, _, _) = make(meds, decisions: decisions)
        await store.load()
        await store.decide(.waitingForVictual(missing: [.product, .unitConversion]), for: "a")
        await store.decide(.skipped, for: "b")
        #expect(store.unsettled.map(\.id) == ["c"])

        let (again, _, _) = make(meds, decisions: decisions)
        await again.load()
        #expect(again.items[0].status == .waitingForVictual([.product, .unitConversion]))
        #expect(again.items[1].status == .skipped)
    }

    @Test func mappingAnItemClearsItsWaitingNote() async {
        let (store, _, _) = make([HealthMedication(ref: "a", displayName: "A")])
        await store.load()
        await store.decide(.waitingForVictual(missing: [.product]), for: "a")
        _ = await store.save(draft(), for: "a")
        guard case .mapped = store.items[0].status else { Issue.record("not mapped"); return }
    }

    @Test func archivedMedicationsAreSeparateAndNotOnTheWizardList() async {
        let (store, _, _) = make([
            HealthMedication(ref: "a", displayName: "A"), HealthMedication(ref: "z", displayName: "Z", isArchived: true),
        ])
        await store.load()
        #expect(store.unsettled.map(\.id) == ["a"])
        #expect(store.archived.map(\.id) == ["z"])
    }

    @Test func theSyncOnlyReadsWhatTheServerMapped() async throws {
        let backend = DemoMedicationBackend()
        let source = ScriptedSource([F.batch([F.dose("D1", ref: "a"), F.dose("D2", ref: "b")])])
        let sync = MedicationSyncStore(
            source: source, submitter: backend, storage: MemoryStateStore(),
            server: "s", account: "me", now: { F.t0 }, zone: { F.zone })
        let store = MedicationSetupStore(
            medicationSource: ScriptedMedications(list: [HealthMedication(ref: "a", displayName: "A"), HealthMedication(ref: "b", displayName: "B")]),
            mappingService: backend, catalog: backend, decisionStore: InMemorySetupDecisionStore(), sync: sync,
            server: "s", account: "me", zone: { F.zone })
        await store.load()
        _ = await store.save(draft(), for: "a")
        await sync.sync()
        #expect(sync.needsMapping == ["b"])  // b has doses and no mapping: nothing sent
        #expect(await backend.hasEvent("D1"))
        #expect(await !backend.hasEvent("D2"))
    }
}
