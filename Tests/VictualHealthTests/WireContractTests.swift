import Foundation
import Testing
@testable import VictualHealth

/// Keeps the hand-written wire types honest against ADR-0041's design fragment.
@Suite("ADR-0041 wire contract")
struct WireContractTests {
    static func fixture(_ name: String) throws -> Data {
        let file = name.hasSuffix(".json") ? name : name + ".json"
        let url = try #require(Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func schemas() throws -> [String: [String: Any]] {
        let root = try #require(JSONSerialization.jsonObject(with: fixture("consumption-events.openapi.json")) as? [String: Any])
        let components = try #require(root["components"] as? [String: Any])
        return try #require(components["schemas"] as? [String: [String: Any]])
    }

    /// The `enum` values the fragment gives a property, with `null` removed.
    static func enumValues(_ schema: String, _ property: String) throws -> Set<String> {
        let properties = try #require(Self.schemas()[schema]?["properties"] as? [String: [String: Any]])
        let values = try #require(properties[property]?["enum"] as? [Any])
        return Set(values.compactMap { $0 as? String })
    }

    @Test func statusMatchesFragment() throws {
        #expect(Set(ConsumptionStatus.allCases.map(\.rawValue)) == (try Self.enumValues("ConsumptionEventSubmission", "status")))
    }

    @Test func stateAndReasonMatchFragment() throws {
        #expect(Set(ConsumptionEventState.allCases.map(\.rawValue)) == (try Self.enumValues("ConsumptionEvent", "state")))
        #expect(Set(ConsumptionReviewReason.allCases.map(\.rawValue)) == (try Self.enumValues("ConsumptionEvent", "reason")))
    }

    @Test func errorKindsMatchFragment() throws {
        #expect(Set(ConsumptionErrorBody.Kind.allCases.map(\.rawValue)) == (try Self.enumValues("Error", "error")))
    }

    @Test func resolutionActionsMatchFragment() throws {
        #expect(Set(ResolutionAction.allCases.map(\.rawValue)) == (try Self.enumValues("ConsumptionEventResolution", "action")))
    }

    @Test func deletionReasonsMatchFragment() throws {
        let root = try #require(JSONSerialization.jsonObject(with: Self.fixture("consumption-events.openapi.json")) as? [String: Any])
        let paths = try #require(root["paths"] as? [String: [String: Any]])
        let delete = try #require(paths["/consumption/events/{source_system}/{source_event_id}"]?["delete"] as? [String: Any])
        let parameters = try #require(delete["parameters"] as? [[String: Any]])
        let schema = try #require(parameters.first { $0["name"] as? String == "reason" }?["schema"] as? [String: Any])
        let values = Set((schema["enum"] as? [String]) ?? [])
        #expect(Set(DeletionReason.allCases.map(\.rawValue)) == values)
    }

    @Test func submissionPropertiesMatchFragment() throws {
        let properties = try #require(Self.schemas()["ConsumptionEventSubmission"]?["properties"] as? [String: Any])
        let full = ConsumptionEventSubmission(
            status: .taken, medicationRef: "m", quantity: 1, unitLabel: "u",
            occurredAt: RFC3339Timestamp(Fixtures.t0, in: .gmt),
            sourceUpdatedAt: RFC3339Timestamp(Fixtures.t0, in: .gmt), locationID: 1, replaces: "x")
        let encoded = try #require(JSONSerialization.jsonObject(with: full.encoded()) as? [String: Any])
        #expect(Set(encoded.keys) == Set(properties.keys))
    }

    @Test func eventPropertiesAreAllKnown() throws {
        // Every property the fragment gives a ConsumptionEvent must decode into a field.
        let properties = try #require(Self.schemas()["ConsumptionEvent"]?["properties"] as? [String: Any])
        let all: [ConsumptionEvent.CodingKeys] = [
            .sourceSystem, .sourceEventID, .state, .reason, .replayed, .stale, .revision, .transactionID,
            .occurredAt, .sourceUpdatedAt, .lines, .candidateLocationIDs, .possibleDuplicates,
            .sourceRemovedAt, .sourceRemovedReason, .unitLabelSeen,
        ]
        let keys = Set(all.map(\.stringValue))
        #expect(keys == Set(properties.keys))
    }

    @Test func adrExamplesDecode() throws {
        let examples = try #require(JSONSerialization.jsonObject(with: Self.fixture("adr-examples")) as? [String: Any])
        func event(_ name: String) throws -> ConsumptionEvent {
            try JSONDecoder().decode(ConsumptionEvent.self, from: JSONSerialization.data(withJSONObject: try #require(examples[name])))
        }
        #expect(try event("needs_mapping").state == .needsMapping)
        #expect(try event("booked").lines?.first?.locationID == 9)
        #expect(try event("replay").replayed == true)
        #expect(try event("late").lines?.first?.usedDate == "2026-10-07")
        #expect(try event("voided").state == .voided)
        #expect(try event("insufficient_stock").reason == .insufficientStock)
        #expect(try event("ambiguous_location").candidateLocationIDs == [9, 11])
        // Present in the ADR's example, absent from the fragment's schema; tolerated, not modelled.
        #expect(try event("replaces").state == .booked)

        let request = try JSONDecoder().decode(
            ConsumptionEventSubmission.self,
            from: JSONSerialization.data(withJSONObject: try #require(examples["request_taken"])))
        #expect(request.status == .taken)
        #expect(request.medicationRef == "hk:med:42")
        #expect(request.occurredAt?.text == "2026-10-09T08:03:00-04:00")
        #expect(request.occurredAt?.date == Date(timeIntervalSince1970: 1_791_547_380))
    }

    @Test func nilQuantityIsOmittedNotNull() throws {
        let body = try ConsumptionEventSubmission(status: .taken, medicationRef: "m", quantity: nil, unitLabel: "tablet").encoded()
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["quantity"] == nil)
        #expect(!String(decoding: body, as: UTF8.self).contains("null"))
    }

    @Test func timestampKeepsItsOriginalOffsetText() throws {
        let stamp = RFC3339Timestamp(Fixtures.t0, in: TimeZone(secondsFromGMT: -4 * 3600)!)
        let back = try JSONDecoder().decode(RFC3339Timestamp.self, from: JSONEncoder().encode(stamp))
        #expect(back.text == stamp.text)
        #expect(stamp.text.hasSuffix("-04:00"))
        #expect(back.date == stamp.date)
    }

    @Test func capabilitiesDecode() throws {
        let body = Data(#"{"contract_version":1,"features":["external_events"]}"#.utf8)
        let capabilities = try JSONDecoder().decode(ConsumptionCapabilities.self, from: body)
        #expect(capabilities == .init(contractVersion: 1, features: ["external_events"]))
    }
}
