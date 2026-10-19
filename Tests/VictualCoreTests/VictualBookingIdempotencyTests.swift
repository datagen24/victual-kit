import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualTestSupport

@testable import VictualCore

private let allOperations = ["purchase", "consume", "transfer", "open", "inventory"]

/// The `Idempotency-Key` is sent only where `/system/info` says it is honoured.
///
/// The gate is what keeps a retry honest: a key sent to a server that ignores
/// it would let a caller believe a second attempt cannot book twice.
@Suite("Stock booking idempotency: the capability gate")
struct BookingIdempotencyGateTests {
    @Test("A server that publishes the capability gets the key, and is asked once")
    func sendsKeyWhenPublished() async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: allOperations),
            answers: [.booked(replayed: false)]
        )
        let client = VictualClient.stubbed(transport)
        let first = StockBookingKey()
        let second = StockBookingKey()

        _ = try await client.consume(productID: 7, amount: 1, idempotencyKey: first)
        _ = try await client.purchase(productID: 7, amount: 1, idempotencyKey: second)

        let sent = transport.recorder.bookings.map { $0.request.headerFields[idempotencyKeyField] }
        #expect(sent == [first.rawValue, second.rawValue])
        let infoRequests = transport.recorder.requests.filter { $0.request.path == "/system/info" }
        #expect(infoRequests.count == 1)
        #expect(client.knownStockBookingIdempotency?.retention == 604_800)
    }

    @Test("A server before 0.5.0 gets no key, and books as it always did")
    func omitsKeyForOlderServer() async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: nil),
            answers: [.booked(replayed: nil)]
        )
        let client = VictualClient.stubbed(transport)

        let booking = try await client.consume(
            productID: 7, amount: 1, idempotencyKey: StockBookingKey()
        )

        #expect(transport.recorder.bookings.count == 1)
        #expect(transport.recorder.bookings[0].request.headerFields[idempotencyKeyField] == nil)
        #expect(booking.isReplayed == nil)
        #expect(client.knownStockBookingIdempotency == nil)
    }

    @Test("Only the operations the server lists get the key")
    func gatesPerOperation() async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: ["consume"]),
            answers: [.booked(replayed: nil)]
        )
        let client = VictualClient.stubbed(transport)

        _ = try await client.consume(productID: 7, amount: 1, idempotencyKey: StockBookingKey())
        _ = try await client.transfer(
            productID: 7, amount: 1, fromLocationID: 1, toLocationID: 2,
            idempotencyKey: StockBookingKey()
        )

        let bookings = transport.recorder.bookings
        #expect(bookings.map { $0.request.path } == ["/stock/products/7/consume", "/stock/products/7/transfer"])
        #expect(bookings[0].request.headerFields[idempotencyKeyField] != nil)
        #expect(bookings[1].request.headerFields[idempotencyKeyField] == nil)
    }

    @Test("Every booking route carries the header", arguments: allOperations)
    func everyRouteCarriesHeader(operation: String) async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: allOperations),
            answers: [.booked(replayed: false)]
        )
        let client = VictualClient.stubbed(transport)
        let key = StockBookingKey()

        switch operation {
        case "purchase": _ = try await client.purchase(productID: 7, amount: 1, idempotencyKey: key)
        case "consume": _ = try await client.consume(productID: 7, amount: 1, idempotencyKey: key)
        case "open": _ = try await client.open(productID: 7, amount: 1, idempotencyKey: key)
        case "inventory": _ = try await client.inventory(productID: 7, newAmount: 1, idempotencyKey: key)
        default:
            _ = try await client.transfer(
                productID: 7, amount: 1, fromLocationID: 1, toLocationID: 2, idempotencyKey: key
            )
        }

        #expect(transport.recorder.bookings.first?.request.headerFields[idempotencyKeyField] == key.rawValue)
    }

    @Test("A changed retention and an unknown operation still decode")
    func openCapabilityValues() async throws {
        let systemInfo = """
            {
              "victual_version": { "Version": "0.5.1", "ReleaseDate": "2026-11-01" },
              "database_engine": "PostgreSQL 16.10",
              "stock_booking_idempotency": {
                "header": "Idempotency-Key",
                "retention_seconds": 86400,
                "operations": ["consume", "undo"]
              }
            }
            """
        let transport = StubTransport.bookingServer(systemInfo: systemInfo, answers: [.booked(replayed: nil)])
        let client = VictualClient.stubbed(transport)

        _ = try await client.verifyConnection()
        let capability = try #require(try await client.stockBookingIdempotency())

        #expect(capability.retention == 86400)
        #expect(capability.operations == [.consume])
    }

    @Test("Without a key the client asks nothing first and sends no header")
    func noKeyNoLookup() async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: allOperations),
            answers: [.booked(replayed: nil)]
        )
        let client = VictualClient.stubbed(transport)

        _ = try await client.consume(productID: 7, amount: 1)

        #expect(transport.recorder.requests.count == 1)
        #expect(transport.recorder.requests[0].request.headerFields[idempotencyKeyField] == nil)
    }

    @Test("Connecting learns the capability, so the first booking asks nothing")
    func verifyConnectionLearnsCapability() async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: allOperations),
            answers: [.booked(replayed: false)]
        )
        let client = VictualClient.stubbed(transport)

        let information = try await client.systemInfo()
        #expect(information.stockBookingIdempotency?.protects(.inventory) == true)
        _ = try await client.inventory(productID: 7, newAmount: 3, idempotencyKey: StockBookingKey())

        let infoRequests = transport.recorder.requests.filter { $0.request.path == "/system/info" }
        #expect(infoRequests.count == 1)
    }

    @Test("A capability lookup that cannot reach the server leaves the booking unkeyed")
    func lookupFailureDoesNotFailBooking() async throws {
        let transport = StubTransport { request, _, _, _ in
            if request.path == "/system/info" { throw URLError(.cannotConnectToHost) }
            return (
                HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                HTTPBody(#"[{"id":1,"product_id":7,"amount":-1,"transaction_id":"tx-1","transaction_type":"consume"}]"#)
            )
        }
        let client = VictualClient.stubbed(transport)

        let booking = try await client.consume(productID: 7, amount: 1, idempotencyKey: StockBookingKey())

        #expect(booking.transactionID == "tx-1")
        #expect(transport.recorder.bookings[0].request.headerFields[idempotencyKeyField] == nil)
        // Not remembered: the next keyed booking asks again.
        #expect(client.knownStockBookingIdempotency == nil)
    }
}

@Suite("Stock booking idempotency: responses")
struct BookingIdempotencyResponseTests {
    @Test(
        "Idempotent-Replayed is read into the booking",
        arguments: [(Bool?.some(true), Bool?.some(true)), (false, false), (nil, nil)]
    )
    func readsReplayedHeader(header: Bool?, expected: Bool?) async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: allOperations),
            answers: [.booked(replayed: header)]
        )
        let client = VictualClient.stubbed(transport)

        let booking = try await client.consume(
            productID: 7, amount: 1, idempotencyKey: StockBookingKey()
        )

        #expect(booking.isReplayed == expected)
    }

    @Test("idempotency_conflict is a defect: distinct, and not worth retrying")
    func mapsConflict() async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: allOperations),
            answers: [.conflict(code: "idempotency_conflict")]
        )
        let client = VictualClient.stubbed(transport)

        let error = await #expect(throws: VictualError.self) {
            _ = try await client.purchase(productID: 7, amount: 1, idempotencyKey: StockBookingKey())
        }

        #expect(error == .idempotencyConflict(message: "refused: idempotency_conflict"))
        #expect(error?.isRetryable == false)
    }

    @Test("idempotency_in_progress means wait: distinct, and retryable")
    func mapsInProgress() async throws {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: allOperations),
            answers: [.conflict(code: "idempotency_in_progress")]
        )
        let client = VictualClient.stubbed(transport)

        let error = await #expect(throws: VictualError.self) {
            _ = try await client.transfer(
                productID: 7, amount: 1, fromLocationID: 1, toLocationID: 2,
                idempotencyKey: StockBookingKey()
            )
        }

        #expect(error == .idempotencyInProgress(message: "refused: idempotency_in_progress"))
        #expect(error?.isRetryable == true)
        #expect(error != .idempotencyConflict(message: "refused: idempotency_in_progress"))
    }
}

@Suite("StockBookingKey")
struct StockBookingKeyTests {
    @Test("A new key fits the header grammar and is not repeated")
    func generatedKeysAreValid() {
        let keys = (0..<100).map { _ in StockBookingKey() }
        #expect(keys.allSatisfy { StockBookingKey(rawValue: $0.rawValue) != nil })
        #expect(Set(keys).count == keys.count)
    }

    @Test(
        "A supplied value must fit 8 to 128 of A-Z a-z 0-9 . _ : -",
        arguments: [
            ("abc.DEF_1:2-3", true), ("1234567", false), (String(repeating: "a", count: 128), true),
            (String(repeating: "a", count: 129), false), ("has space1", false), ("ünïcode-key", false),
        ]
    )
    func validatesGrammar(value: String, valid: Bool) {
        #expect((StockBookingKey(rawValue: value) != nil) == valid)
    }
}
