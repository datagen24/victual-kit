import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualCore
import VictualTestSupport
@testable import VictualHealth

@Suite("Real consumption service")
struct VictualConsumptionServiceTests {
    private func service(status: Int = 200, json: String) -> (VictualConsumptionService, StubTransport) {
        let transport = StubTransport(status: status, json: json)
        return (VictualConsumptionService(client: .stubbed(transport)), transport)
    }

    private let booked = #"{"source_system":"healthkit","source_event_id":"E1","state":"booked","occurred_at":"2026-10-09T12:03:00.000000Z","lines":[{"product_id":17,"amount":1,"location_id":9}]}"#

    @Test func aPutSendsExactlyTheStoredBytes() async throws {
        let (service, transport) = service(json: booked)
        let submission = ConsumptionEventSubmission(
            status: .taken, medicationRef: "hk:med:42", quantity: 1, unitLabel: "tablet",
            occurredAt: RFC3339Timestamp(Fixtures.t0, in: Fixtures.zone), sourceUpdatedAt: RFC3339Timestamp(Fixtures.t0, in: Fixtures.zone))
        let stored = try submission.encoded()

        let event = try await service.put(submission, sourceEventID: "E1")

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.request.method == .put)
        #expect(sent.url.path.hasSuffix("/consumption/events/healthkit/E1"))
        #expect(sent.body == stored)  // byte-identical, so a replay cannot become a conflict
        #expect(event.state == .booked)
        #expect(event.lines?.first?.locationID == 9)
    }

    @Test func aReplayRoundTripsThroughStorageUnchanged() async throws {
        let submission = ConsumptionEventSubmission(
            status: .taken, medicationRef: "m", occurredAt: RFC3339Timestamp(Fixtures.t0, in: Fixtures.zone))
        let first = try submission.encoded()
        let restored = try JSONDecoder().decode(ConsumptionEventSubmission.self, from: first)
        #expect(try restored.encoded() == first)
    }

    @Test func aDeleteCarriesTheReasonOnlyWhenThereIsOne() async throws {
        let (service, transport) = service(json: #"{"source_system":"healthkit","source_event_id":"E1","state":"voided"}"#)
        _ = try await service.delete(sourceEventID: "E1", reason: .accessRevoked)
        _ = try await service.delete(sourceEventID: "E1", reason: nil)
        let urls = transport.recorder.requests.map(\.url)
        #expect(urls[0].query == "reason=access_revoked")
        #expect(urls[1].query == nil)
    }

    @Test func bulkResolveIsOneRequestPer50AndReportsEachEvent() async throws {
        let (service, transport) = service(
            json: #"{"results":[{"source_system":"healthkit","source_event_id":"E1","http_status":200,"event":{"source_system":"healthkit","source_event_id":"E1","state":"voided"}},{"source_system":"healthkit","source_event_id":"E2","http_status":422,"error":{"error_message":"nope","error":"invalid_transition"}}]}"#)
        let ids = (1...120).map { "E\($0)" }

        let outcomes = try await service.resolve(sourceEventIDs: ids, action: .void)

        #expect(transport.recorder.requests.count == 3)  // 50 + 50 + 20
        let first = try #require(transport.recorder.requests.first)
        #expect(first.url.path.hasSuffix("/consumption/events/resolve"))
        let body = try #require(first.jsonBody)
        #expect(body["action"] as? String == "void")
        #expect((body["events"] as? [[String: String]])?.count == 50)
        #expect(outcomes.prefix(2).map(\.httpStatus) == [200, 422])
        #expect(outcomes[1].errorMessage == "nope")
        #expect(outcomes[0].event?.state == .voided)
    }

    @Test func capabilitiesToleratesFeaturesItDoesNotKnow() async throws {
        let (service, _) = service(json: #"{"contract_version":1,"features":["events","from_the_future"]}"#)
        #expect(try await service.capabilities().features == ["events", "from_the_future"])
    }

    @Test func aMissingCapabilitiesRouteIsAnOlderServer() async {
        let (service, _) = service(status: 404, json: #"{"error_message":"Not found"}"#)
        await #expect(throws: VictualError.notFound) { try await service.capabilities() }
    }

    @Test func anUnknownReasonFromANewerServerFailsLoudly() async {
        let (service, _) = service(json: #"{"source_system":"healthkit","source_event_id":"E1","state":"needs_review","reason":"brand_new"}"#)
        await #expect(throws: VictualError.self) {
            try await service.resolve(sourceEventID: "E1", action: .retry)
        }
    }

    @Test func serverRefusalsKeepTheirMessage() async {
        let (service, _) = service(status: 422, json: #"{"error_message":"No conversion","error":"invalid_mapping"}"#)
        let input = ConsumptionMappingInput(
            productID: 1, location: .init(mode: .single), effectiveFrom: RFC3339Timestamp(Fixtures.t0, in: .gmt))
        await #expect(throws: VictualError.badRequest(message: "No conversion")) {
            try await service.put(input, medicationRef: "m")
        }
    }

    @Test func aMappingRoundTripsWithItsUnit() async throws {
        let json = #"{"source_system":"healthkit","medication_ref":"m","product_id":1,"qu_id":2,"quantity_factor":1,"unit_labels":["tablet"],"default_quantity":null,"location":{"mode":"fixed","location_id":9},"effective_from":"2026-10-09T00:00:00-04:00"}"#
        let (service, transport) = service(json: json)
        let input = ConsumptionMappingInput(
            productID: 1, quantityFactor: 1, location: .init(mode: .fixed, locationID: 9),
            effectiveFrom: RFC3339Timestamp(Fixtures.t0, in: .gmt), unitID: 2)
        let mapping = try await service.put(input, medicationRef: "m")
        #expect(mapping.input.unitID == 2)
        #expect(transport.recorder.requests[0].url.path.hasSuffix("/consumption/mappings/healthkit/m"))
        #expect(transport.recorder.requests[0].jsonBody?["qu_id"] as? Int == 2)
    }
}
