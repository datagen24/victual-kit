import Foundation
import VictualCore

/// What the refill store reads. ``VictualRefillService`` is the real one.
public protocol RefillSource: Sendable {
    /// Feature names the server lists (`GET /consumption/capabilities`).
    func capabilities() async throws -> ConsumptionCapabilities
    /// `GET /refills?as_of=` for every prescription the caller can read.
    func refills(asOf: CalendarDay) async throws -> [RefillItem]
    /// `GET /refills/notices?as_of=`: the caller's unacknowledged notices.
    func notices(asOf: CalendarDay) async throws -> [RefillNotice]
    /// `POST /refills/notices/ack`. Idempotent.
    func acknowledge(noticeKey: String) async throws
    /// `GET /consumption/recipes/{id}/refill?as_of=`: the fills, voided ones included.
    func fills(recipeID: Int, asOf: CalendarDay) async throws -> [RefillFillRecord]
}

/// The refill routes of ADR-0042 over a ``VictualClient``. Read-only apart from the
/// acknowledgement: the phone records no fills and no orders.
public struct VictualRefillService: RefillSource {
    private let client: VictualClient

    public init(client: VictualClient) {
        self.client = client
    }

    public func capabilities() async throws -> ConsumptionCapabilities {
        try await VictualConsumptionService(client: client).capabilities()
    }

    public func refills(asOf: CalendarDay) async throws -> [RefillItem] {
        let response = try await client.send(
            .get, path: "/refills", query: [("as_of", asOf.description)], operationID: "getRefills")
        let list = try Self.decode(RefillListWire.self, response.data)
        return try Self.adapt { try (list.refills ?? []).map(RefillItem.init(wire:)) }
    }

    public func notices(asOf: CalendarDay) async throws -> [RefillNotice] {
        let response = try await client.send(
            .get, path: "/refills/notices", query: [("as_of", asOf.description)], operationID: "getRefillsNotices")
        let list = try Self.decode(RefillNoticeListWire.self, response.data)
        return try Self.adapt { try (list.notices ?? []).map(RefillNotice.init(wire:)) }
    }

    public func acknowledge(noticeKey: String) async throws {
        let body = try JSONEncoder().encode(["notice_key": noticeKey])
        _ = try await client.send(.post, path: "/refills/notices/ack", body: body, operationID: "postRefillsNoticesAck")
    }

    public func fills(recipeID: Int, asOf: CalendarDay) async throws -> [RefillFillRecord] {
        let response = try await client.send(
            .get, path: "/consumption/recipes/\(recipeID)/refill", query: [("as_of", asOf.description)],
            operationID: "getConsumptionRecipesByRecipeIdRefill")
        let wire = try Self.decode(RefillWire.self, response.data)
        return (wire.fills ?? []).compactMap(RefillFillRecord.init(wire:))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw VictualError.decodingFailed(underlying: error) }
    }

    private static func adapt<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch { throw VictualError.decodingFailed(underlying: error) }
    }
}
