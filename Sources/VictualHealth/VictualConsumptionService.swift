import Foundation
import HTTPTypes
import VictualAPI
import VictualCore

/// The real ADR-0041 client: events, mappings and capabilities over a ``VictualClient``.
///
/// ## Which types are generated and which are not
///
/// **Responses are decoded into the generated schema types** (`ConsumptionExternalEvent`,
/// the bulk result, the recipe summary) and then adapted to the values the sync
/// persists. A server answer that does not fit the specification is a
/// `decodingFailed` failure, shown to the person, rather than a guess.
///
/// **Requests are not generated**, for two reasons:
/// - A medication event is stored in the outbox and replayed after a crash or a
///   retry, and the server compares the payload hash. ``ConsumptionEventSubmission``
///   keeps the timestamps as the text first rendered, so a replay is byte-identical;
///   a generated request type holds a `Date` and would re-render the offset in
///   force *now*. The PUT therefore sends the stored bytes through ``VictualClient/send(_:path:query:body:operationID:)``.
/// - The mapping and capabilities types stay hand-written because a generated
///   `@frozen` enum fails to decode a feature name or value a newer server adds,
///   which for capabilities would turn "a feature this client does not know" into
///   "no medication sync at all".
///
/// `WireContractTests` pins the hand-written enums to the generated ones, so
/// a spec change that adds a case fails a test instead of passing silently.
public struct VictualConsumptionService: ConsumptionEventSubmitter, ConsumptionMappingService {
    private let client: VictualClient

    public init(client: VictualClient) {
        self.client = client
    }

    private static let events = "/consumption/events/\(VictualHealth.sourceSystem)"

    // MARK: Events

    public func put(_ submission: ConsumptionEventSubmission, sourceEventID: String) async throws -> ConsumptionEvent {
        let response = try await client.send(
            .put, path: "\(Self.events)/\(sourceEventID)", body: try submission.encoded(), operationID: "putConsumptionEvent")
        return try event(from: response)
    }

    public func delete(sourceEventID: String, reason: DeletionReason?) async throws -> ConsumptionEvent {
        let query = reason.map { [(name: "reason", value: $0.rawValue)] } ?? []
        let response = try await client.send(
            .delete, path: "\(Self.events)/\(sourceEventID)", query: query, operationID: "deleteConsumptionEvent")
        return try event(from: response)
    }

    public func resolve(sourceEventID: String, action: ResolutionAction) async throws -> ConsumptionEvent {
        let body = try JSONEncoder().encode(["action": action.rawValue])
        let response = try await client.send(
            .post, path: "\(Self.events)/\(sourceEventID)/resolve", body: body, operationID: "resolveConsumptionEvent")
        return try event(from: response)
    }

    /// At most 50 events per request, as the server limits it; longer lists are chunked.
    public func resolve(sourceEventIDs: [String], action: ResolutionAction) async throws -> [BulkResolveOutcome] {
        var outcomes: [BulkResolveOutcome] = []
        for start in stride(from: 0, to: sourceEventIDs.count, by: 50) {
            let chunk = sourceEventIDs[start..<min(start + 50, sourceEventIDs.count)]
            let body = try JSONEncoder().encode(
                BulkBody(action: action.rawValue, events: chunk.map { .init(sourceSystem: VictualHealth.sourceSystem, sourceEventID: $0) }))
            let response = try await client.send(
                .post, path: "/consumption/events/resolve", body: body, operationID: "bulkResolveConsumptionEvents")
            let result = try client.decode(Components.Schemas.ConsumptionBulkResolutionResult.self, from: response.data)
            for item in result.results {
                outcomes.append(
                    BulkResolveOutcome(
                        sourceEventID: item.sourceEventId, httpStatus: item.httpStatus,
                        event: try item.event.map(ConsumptionEvent.init),
                        errorMessage: item.error?.errorMessage))
            }
        }
        return outcomes
    }

    private struct BulkBody: Encodable {
        struct Reference: Encodable {
            var sourceSystem: String
            var sourceEventID: String
            enum CodingKeys: String, CodingKey {
                case sourceSystem = "source_system"
                case sourceEventID = "source_event_id"
            }
        }
        var action: String
        var events: [Reference]
    }

    public func capabilities() async throws -> ConsumptionCapabilities {
        let response = try await client.send(.get, path: "/consumption/capabilities", operationID: "getConsumptionCapabilities")
        do {
            return try JSONDecoder().decode(ConsumptionCapabilities.self, from: response.data)
        } catch {
            throw VictualError.decodingFailed(underlying: error)
        }
    }

    private func event(from response: VictualRawResponse) throws -> ConsumptionEvent {
        try ConsumptionEvent(client.decode(Components.Schemas.ConsumptionExternalEvent.self, from: response.data))
    }

    // MARK: Mappings

    private func mappingPath(_ ref: String) -> String { "/consumption/mappings/\(VictualHealth.sourceSystem)/\(ref)" }

    public func mappings() async throws -> [ConsumptionMapping] {
        let response = try await client.send(.get, path: "/consumption/mappings", operationID: "listConsumptionMappings")
        do {
            return try JSONDecoder().decode([ConsumptionMapping].self, from: response.data)
        } catch {
            throw VictualError.decodingFailed(underlying: error)
        }
    }

    public func put(_ input: ConsumptionMappingInput, medicationRef: String) async throws -> ConsumptionMapping {
        let response = try await client.send(
            .put, path: mappingPath(medicationRef), body: try JSONEncoder().encode(input), operationID: "putConsumptionMapping")
        do {
            return try JSONDecoder().decode(ConsumptionMapping.self, from: response.data)
        } catch {
            throw VictualError.decodingFailed(underlying: error)
        }
    }

    public func delete(medicationRef: String) async throws {
        _ = try await client.send(.delete, path: mappingPath(medicationRef), operationID: "deleteConsumptionMapping")
    }
}

extension ConsumptionEvent {
    /// Adapts a generated server event. A state or reason this client does not
    /// know is a decoding failure, not a default.
    init(_ generated: Components.Schemas.ConsumptionExternalEvent) throws {
        guard let state = ConsumptionEventState(rawValue: generated.state.rawValue) else {
            throw VictualError.decodingFailed(underlying: AdaptationError.unknown("state \(generated.state.rawValue)"))
        }
        var reason: ConsumptionReviewReason?
        if let raw = generated.reason?.rawValue, !raw.isEmpty {
            guard let known = ConsumptionReviewReason(rawValue: raw) else {
                throw VictualError.decodingFailed(underlying: AdaptationError.unknown("reason \(raw)"))
            }
            reason = known
        }
        self.init(
            sourceSystem: generated.sourceSystem, sourceEventID: generated.sourceEventId, state: state, reason: reason,
            possibleDuplicates: generated.possibleDuplicates?.map {
                PossibleDuplicate(transactionID: $0.transactionId, occurredAt: $0.occurredAt.map { RFC3339Timestamp($0, in: .gmt) })
            },
            unitLabelSeen: generated.unitLabelSeen)
        replayed = generated.replayed
        stale = generated.stale
        revision = generated.revision
        transactionID = generated.transactionId
        occurredAt = generated.occurredAt.map { RFC3339Timestamp($0, in: .gmt) }
        sourceUpdatedAt = generated.sourceUpdatedAt.map { RFC3339Timestamp($0, in: .gmt) }
        candidateLocationIDs = generated.candidateLocationIds
        sourceRemovedAt = generated.sourceRemovedAt.map { RFC3339Timestamp($0, in: .gmt) }
        sourceRemovedReason = generated.sourceRemovedReason
        message = generated.message
        lines = generated.lines?.map {
            Line(productID: $0.productId, amount: $0.amount, locationID: $0.locationId, usedDate: $0.usedDate)
        }
    }

    enum AdaptationError: Error { case unknown(String) }
}
