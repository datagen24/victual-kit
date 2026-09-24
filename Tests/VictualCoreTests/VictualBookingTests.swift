import Foundation
import HTTPTypes
import Testing
import VictualTestSupport

@testable import VictualCore

/// A booking response with two rows under one transaction, which is the normal
/// shape: one user action commonly touches several stock entries.
///
/// `spoiled` is `false`, not `0`: the column is an `integer`, but since Victual
/// 0.2.0-MVP the server converts it to the `boolean` the document promises
/// (issue #230).
private let bookingJSON = """
    [
      {
        "id": 401, "product_id": 7, "amount": -1, "transaction_id": "tx-abc",
        "transaction_type": "consume", "spoiled": false, "stock_id": "lot-1",
        "price": null, "used_date": "2026-09-21",
        "row_created_timestamp": "2026-09-21 09:14:02"
      },
      {
        "id": 402, "product_id": 7, "amount": -1, "transaction_id": "tx-abc",
        "transaction_type": "consume", "spoiled": false, "stock_id": "lot-2",
        "price": null, "used_date": "2026-09-21",
        "row_created_timestamp": "2026-09-21 09:14:02"
      }
    ]
    """

/// Asserts on the JSON body a booking actually puts on the wire.
///
/// This is the test that catches a field renamed by a specification re-sync.
/// The domain wrappers would still compile against a renamed generated property
/// — the generator would have renamed it on both sides — and the failure would
/// only show up against a real server. Pinning the encoded body here turns that
/// into a failing test instead.
@Suite("Booking request bodies")
struct BookingRequestBodyTests {
    private func send(
        _ booking: (VictualClient) async throws -> Void
    ) async throws -> (path: String, method: HTTPRequest.Method, json: [String: Any]) {
        let transport = StubTransport(status: 200, json: bookingJSON)
        try await booking(VictualClient.stubbed(transport))
        let sent = try #require(transport.recorder.requests.first)
        let json = try #require(sent.jsonBody, "the booking sent no JSON body")
        return (try #require(sent.request.path), sent.request.method, json)
    }

    @Test("consume encodes every documented field")
    func consumeBody() async throws {
        let sent = try await send { client in
            _ = try await client.consume(
                productID: 7,
                amount: 2,
                spoiled: true,
                recipeID: 19,
                locationID: 4,
                allowSubproductSubstitution: true
            )
        }

        #expect(sent.path == "/stock/products/7/consume")
        #expect(sent.method == .post)
        #expect(sent.json["amount"] as? Double == 2)
        #expect(sent.json["transaction_type"] as? String == "consume")
        #expect(sent.json["spoiled"] as? Bool == true)
        #expect(sent.json["recipe_id"] as? Int == 19)
        #expect(sent.json["location_id"] as? Int == 4)
        #expect(sent.json["allow_subproduct_substitution"] as? Bool == true)
        // Not named, so not sent: an absent optional must not become a null the
        // server then has to interpret.
        #expect(sent.json["stock_entry_id"] == nil)
    }

    @Test("consume names a single stock entry")
    func consumeSingleEntryBody() async throws {
        let sent = try await send { client in
            _ = try await client.consume(productID: 7, amount: 1, stockEntryID: "lot-1")
        }

        #expect(sent.json["stock_entry_id"] as? String == "lot-1")
        #expect(sent.json["amount"] as? Double == 1)
    }

    @Test("purchase encodes every documented field")
    func purchaseBody() async throws {
        let due = try #require(VictualDates.day("2026-01-31"))
        let sent = try await send { client in
            _ = try await client.purchase(
                productID: 7,
                amount: 3,
                bestBeforeDate: due,
                price: 1.99,
                locationID: 4,
                shoppingLocationID: 2,
                stockLabelType: .perUnit,
                note: "on offer"
            )
        }

        #expect(sent.path == "/stock/products/7/add")
        #expect(sent.json["amount"] as? Double == 3)
        // Round-tripped through the day formatter, not through ISO 8601.
        #expect(sent.json["best_before_date"] as? String == "2026-01-31")
        #expect(sent.json["transaction_type"] as? String == "purchase")
        #expect(sent.json["price"] as? Double == 1.99)
        #expect(sent.json["location_id"] as? Int == 4)
        #expect(sent.json["shopping_location_id"] as? Int == 2)
        #expect(sent.json["stock_label_type"] as? Int == 3)
        #expect(sent.json["note"] as? String == "on offer")
    }

    @Test("purchase omits a price it was not given")
    func purchaseWithoutPrice() async throws {
        let sent = try await send { client in
            _ = try await client.purchase(productID: 7, amount: 1)
        }

        // Not zero, and not null: a purchase with no price recorded must not
        // claim the household paid nothing.
        #expect(sent.json["price"] == nil)
        #expect(sent.json["best_before_date"] == nil)
    }

    @Test("open encodes its measurement")
    func openBody() async throws {
        let sent = try await send { client in
            _ = try await client.open(
                productID: 7,
                amount: 1,
                stockEntryID: "lot-1",
                allowSubproductSubstitution: true,
                measurement: .gross(482.5, unitID: 3, tare: 60)
            )
        }

        #expect(sent.path == "/stock/products/7/open")
        #expect(sent.json["amount"] as? Double == 1)
        #expect(sent.json["stock_entry_id"] as? String == "lot-1")
        #expect(sent.json["allow_subproduct_substitution"] as? Bool == true)

        let measurement = try #require(sent.json["measurement"] as? [String: Any])
        #expect(measurement["amount"] as? Double == 482.5)
        #expect(measurement["qu_id"] as? Int == 3)
        #expect(measurement["gross"] as? Bool == true)
        #expect(measurement["tare"] as? Double == 60)
    }

    @Test("open without a measurement sends none")
    func openWithoutMeasurement() async throws {
        let sent = try await send { client in
            _ = try await client.open(productID: 7, amount: 2)
        }

        #expect(sent.json["measurement"] == nil)
        #expect(sent.json["amount"] as? Double == 2)
    }

    @Test("inventory encodes every documented field")
    func inventoryBody() async throws {
        let due = try #require(VictualDates.day("2026-03-15"))
        let sent = try await send { client in
            _ = try await client.inventory(
                productID: 7,
                newAmount: 12,
                bestBeforeDate: due,
                locationID: 4,
                shoppingLocationID: 2,
                price: 0.75,
                stockLabelType: .single,
                note: "counted"
            )
        }

        #expect(sent.path == "/stock/products/7/inventory")
        // `new_amount`, not `amount`: an inventory states a total, not a delta.
        #expect(sent.json["new_amount"] as? Double == 12)
        #expect(sent.json["amount"] == nil)
        #expect(sent.json["best_before_date"] as? String == "2026-03-15")
        #expect(sent.json["location_id"] as? Int == 4)
        #expect(sent.json["shopping_location_id"] as? Int == 2)
        #expect(sent.json["price"] as? Double == 0.75)
        #expect(sent.json["stock_label_type"] as? Int == 2)
        #expect(sent.json["note"] as? String == "counted")
    }

    @Test("transfer encodes every documented field")
    func transferBody() async throws {
        let sent = try await send { client in
            _ = try await client.transfer(
                productID: 7,
                amount: 1,
                fromLocationID: 4,
                toLocationID: 9,
                stockEntryID: "lot-1"
            )
        }

        #expect(sent.path == "/stock/products/7/transfer")
        #expect(sent.json["amount"] as? Double == 1)
        #expect(sent.json["location_id_from"] as? Int == 4)
        #expect(sent.json["location_id_to"] as? Int == 9)
        #expect(sent.json["stock_entry_id"] as? String == "lot-1")
    }

    @Test("undo addresses the transaction and sends no body")
    func undoRequest() async throws {
        let transport = StubTransport { _, _, _, _ in
            (HTTPResponse(status: .noContent), nil)
        }
        let client = VictualClient.stubbed(transport)

        try await client.undoTransaction(id: "tx-abc")

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.request.path == "/stock/transactions/tx-abc/undo")
        #expect(sent.request.method == .post)
        #expect(sent.body == nil)
    }
}

@Suite("Booking results")
struct BookingResultTests {
    @Test("Groups the rows of one action under their shared transaction")
    func groupsRows() async throws {
        let client = VictualClient.stubbed(StubTransport(status: 200, json: bookingJSON))

        let booking = try await client.consume(productID: 7, amount: 2)

        #expect(booking.transactionID == "tx-abc")
        #expect(booking.rows.count == 2)
        #expect(booking.isUndoable)
        #expect(booking.productID == 7)
        #expect(booking.totalAmount == -2)
        #expect(booking.rows.first?.transactionType == .consume)
        #expect(booking.rows.first?.stockID == "lot-1")
        #expect(booking.rows.first?.spoiled == false)
    }

    @Test("A consumption's null price is not a zero")
    func consumptionHasNoPrice() async throws {
        let client = VictualClient.stubbed(StubTransport(status: 200, json: bookingJSON))

        let booking = try await client.consume(productID: 7, amount: 2)

        #expect(booking.rows.first?.price == nil)
    }

    @Test("A spoiled row reads back as spoiled")
    func spoiledFlagMapsToBool() async throws {
        let json = #"[{"id": 1, "product_id": 7, "amount": -1, "spoiled": true, "transaction_id": "t"}]"#
        let client = VictualClient.stubbed(StubTransport(status: 200, json: json))

        let booking = try await client.consume(productID: 7, amount: 1, spoiled: true)

        #expect(booking.rows.first?.spoiled == true)
    }

    @Test("A booking with no transaction id is not offered for undo")
    func withoutTransactionID() async throws {
        let json = #"[{"id": 1, "product_id": 7, "amount": -1}]"#
        let client = VictualClient.stubbed(StubTransport(status: 200, json: json))

        let booking = try await client.consume(productID: 7, amount: 1)

        #expect(booking.transactionID == nil)
        #expect(!booking.isUndoable)
    }

    @Test("Maps a missing permission to .forbidden")
    func mapsForbidden() async throws {
        let transport = StubTransport(
            status: 403,
            json: #"{"error_message":"Missing permission STOCK_CONSUME"}"#
        )
        let client = VictualClient.stubbed(transport)

        await #expect(throws: VictualError.forbidden) {
            _ = try await client.consume(productID: 7, amount: 1)
        }
    }
}

/// Rejections the wrappers make locally, before spending a round trip.
@Suite("Booking preconditions")
struct BookingPreconditionTests {
    @Test(
        "Naming a stock entry with any amount but 1 never reaches the transport",
        arguments: [2.0, 0.5, 0.0, -1.0]
    )
    func rejectsMultiUnitEntryBooking(amount: Double) async throws {
        let transport = StubTransport(status: 200, json: bookingJSON)
        let client = VictualClient.stubbed(transport)

        let error = await #expect(throws: VictualError.self) {
            _ = try await client.consume(productID: 7, amount: amount, stockEntryID: "lot-1")
        }
        guard case .badRequest = try #require(error) else {
            Issue.record("expected .badRequest, got \(String(describing: error))")
            return
        }
        #expect(transport.recorder.requests.isEmpty)
    }

    @Test("The same rule applies to open and transfer")
    func rejectsAcrossBookings() async throws {
        let transport = StubTransport(status: 200, json: bookingJSON)
        let client = VictualClient.stubbed(transport)

        await #expect(throws: VictualError.self) {
            _ = try await client.open(productID: 7, amount: 3, stockEntryID: "lot-1")
        }
        await #expect(throws: VictualError.self) {
            _ = try await client.transfer(
                productID: 7, amount: 3, fromLocationID: 1, toLocationID: 2, stockEntryID: "lot-1"
            )
        }
        #expect(transport.recorder.requests.isEmpty)
    }

    @Test("An amount of 1 with a stock entry is allowed through")
    func allowsSingleUnitEntryBooking() async throws {
        let transport = StubTransport(status: 200, json: bookingJSON)
        let client = VictualClient.stubbed(transport)

        _ = try await client.consume(productID: 7, amount: 1, stockEntryID: "lot-1")

        #expect(transport.recorder.requests.count == 1)
    }

    @Test("A measurement needs a single named container")
    func rejectsUnanchoredMeasurement() async throws {
        let transport = StubTransport(status: 200, json: bookingJSON)
        let client = VictualClient.stubbed(transport)

        // No stock entry to describe.
        await #expect(throws: VictualError.self) {
            _ = try await client.open(
                productID: 7, amount: 1, measurement: .net(200, unitID: 3)
            )
        }
        // A gross reading with nothing to subtract.
        await #expect(throws: VictualError.self) {
            _ = try await client.open(
                productID: 7,
                amount: 1,
                stockEntryID: "lot-1",
                measurement: OpenMeasurement(amount: 480, quantityUnitID: 3, isGross: true)
            )
        }
        #expect(transport.recorder.requests.isEmpty)
    }

    @Test("A transfer to the same location is refused locally")
    func rejectsSelfTransfer() async throws {
        let transport = StubTransport(status: 200, json: bookingJSON)
        let client = VictualClient.stubbed(transport)

        await #expect(throws: VictualError.self) {
            _ = try await client.transfer(
                productID: 7, amount: 1, fromLocationID: 4, toLocationID: 4
            )
        }
        #expect(transport.recorder.requests.isEmpty)
    }
}
