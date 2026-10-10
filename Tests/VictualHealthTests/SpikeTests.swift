import Foundation
import Testing
@testable import VictualHealth

@Suite("medication_ref derivation")
struct MedicationRefTests {
    @Test(arguments: ["abc", "hk:med:42", "a.b_c-d:e", String(repeating: "a", count: 128)])
    func validReferences(text: String) {
        #expect(MedicationRef.isValid(text))
    }

    @Test(arguments: ["", "has space", "<HKHealthConceptIdentifier: 0x12>", "naïve", String(repeating: "a", count: 129)])
    func invalidReferences(text: String) {
        #expect(!MedicationRef.isValid(text))
    }

    @Test func hashIsPrefixedLowercaseHexOfTheArchive() {
        let ref = MedicationRef.hashed(archive: Data("x".utf8))
        // SHA-256("x")
        #expect(ref == "hk:med:2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
        #expect(MedicationRef.isValid(ref))
    }

    @Test func aValidDescriptionWinsAndAPointerStringFallsBack() {
        let archive = Data([1, 2, 3])
        #expect(MedicationRef.choose(description: "med-123", archive: archive) == "med-123")
        let pointer = "<HKHealthConceptIdentifier: 0x600000>"
        #expect(MedicationRef.choose(description: pointer, archive: archive) == MedicationRef.hashed(archive: archive))
        #expect(MedicationRef.choose(description: nil, archive: archive) == MedicationRef.hashed(archive: archive))
    }

    @Test func candidatesRecordBothForms() {
        let archive = Data([9])
        let candidates = MedicationRef.candidates(description: "has space", archive: archive)
        #expect(candidates.description == "has space")
        #expect(!candidates.descriptionIsValid)
        #expect(candidates.hashed == MedicationRef.hashed(archive: archive))
        #expect(candidates.chosen == candidates.hashed)
    }
}

@Suite("Spike report export")
struct SpikeReportTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let environment = SpikeEnvironment(deviceModel: "iPhone17,3", osVersion: "Version 27.0", buildConfiguration: "Debug")

    private func medication(description: String?, embedsName: Bool) -> SpikeMedicationFinding {
        SpikeMedicationFinding(
            label: "M1", candidates: MedicationRef.candidates(description: description, archive: Data([7])),
            archiveRepeatable: true, archiveRoundTrips: true, descriptionSeenLastLaunch: nil, hashSeenLastLaunch: true,
            isArchived: false, hasSchedule: true, generalForm: "tablet", hasNickname: true,
            descriptionContainsName: embedsName)
    }

    private func snapshot(_ medications: [SpikeMedicationFinding], events: [SpikeEventFinding] = []) -> SpikeSnapshot {
        SpikeSnapshot(
            environment: environment, authorizationRequests: 2, medications: medications, events: events,
            revocations: [], backgroundDelivery: "accepted", unknownStatusCount: 0,
            generatedAt: Date(timeIntervalSince1970: 1_791_000_059))  // seconds are dropped
    }

    @Test func timesAreRoundedDownToTheMinute() {
        let start = Date(timeIntervalSince1970: 1_791_000_059)
        let event = SpikeEventFinding(
            kind: .inserted, shortID: "ab12", arrivedAt: start.addingTimeInterval(7), medicationLabel: "M1",
            status: "taken", scheduleType: "asNeeded", doseQuantity: 1, unitString: "tablet", startDate: start,
            endDate: start, initialDelivery: false)
        let text = SpikeReport.render(snapshot([medication(description: nil, embedsName: false)], events: [event]), timeZone: utc)
        #expect(text.contains("2026-10-03 04:00"))
        #expect(!text.contains("04:00:"))
        #expect(text.contains("7 s after start"))
        #expect(text.contains("doseQuantity 1 "))
        #expect(text.contains("unit \"tablet\""))
        #expect(text.contains("id#ab12"))
    }

    @Test func nilQuantityAndUnitAreStatedNotInvented() {
        let event = SpikeEventFinding(kind: .inserted, shortID: "cd34", arrivedAt: Date(), initialDelivery: true)
        let text = SpikeReport.render(snapshot([], events: [event]), timeZone: utc)
        #expect(text.contains("doseQuantity nil"))
        #expect(text.contains("scheduledDoseQuantity nil"))
    }

    @Test func aDescriptionThatEmbedsANameIsWithheld() {
        let leaky = medication(description: "Examplepril-10", embedsName: true)
        let text = SpikeReport.render(snapshot([leaky]), timeZone: utc)
        #expect(!text.contains("Examplepril"))
        #expect(text.contains("withheld"))
        #expect(text.contains(leaky.candidates.hashed))
    }

    @Test func aCleanDescriptionIsShown() {
        let clean = medication(description: "opaque-ref-1", embedsName: false)
        let text = SpikeReport.render(snapshot([clean]), timeZone: utc)
        #expect(text.contains("\"opaque-ref-1\" valid yes"))
        #expect(text.contains("seen at previous launch: description n/a (first launch), hash yes"))
    }

    @Test func theReportCarriesBothCandidatesAndTheEnvironment() {
        let text = SpikeReport.render(snapshot([medication(description: nil, embedsName: false)]), timeZone: utc)
        #expect(text.contains("iPhone17,3"))
        #expect(text.contains("Background delivery for dose events: accepted"))
        #expect(text.contains("description candidate: none"))
        #expect(text.contains("hash candidate: hk:med:"))
    }
}
