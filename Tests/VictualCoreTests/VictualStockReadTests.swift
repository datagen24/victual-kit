import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualTestSupport

@testable import VictualCore

/// The rule that a price a caller may not see is **absent**, not null and not
/// zero.
///
/// This is the one a future change is most likely to break silently: adding a
/// `?? 0` to make a type non-optional compiles, reads sensibly, and quietly
/// turns "we are not allowed to know" into "the household paid nothing".
@Suite("Price redaction")
struct PriceRedactionTests {
    /// The same row twice: as a caller with `STOCK_PRICES_VIEW` sees it, and as
    /// a caller without sees it. The server omits the field rather than nulling
    /// it, which is what the second body shows.
    @Test("A stock row without `value` decodes to nil, not zero")
    func absentValueIsNil() async throws {
        let redacted = """
            [{"product_id": 7, "amount": 2.5, "best_before_date": "2026-01-31"}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: redacted))

        let row = try #require(try await client.currentStock().first)

        #expect(row.value == nil)
        #expect(row.value != 0)
        #expect(row.amount == 2.5)
    }

    @Test("A stock row with `value` keeps it")
    func presentValueSurvives() async throws {
        let permitted = """
            [{"product_id": 7, "amount": 2.5, "value": 12.75}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: permitted))

        let row = try #require(try await client.currentStock().first)

        #expect(row.value == 12.75)
    }

    @Test("An explicit null is also nil rather than zero")
    func nullValueIsNil() async throws {
        // `value` is not documented as nullable, but a nulled field must not
        // become a zero either.
        let nulled = #"[{"product_id": 7, "amount": 1, "value": null}]"#
        let client = VictualClient.stubbed(StubTransport(status: 200, json: nulled))

        let row = try #require(try await client.currentStock().first)

        #expect(row.value == nil)
    }

    @Test("All four of a product detail's prices go absent together")
    func productDetailPricesAbsent() async throws {
        let redacted = """
            {
              "product": {"id": 7, "name": "Cookies", "qu_id_stock": 3},
              "stock_amount": 2, "next_due_date": "2026-01-31"
            }
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: redacted))

        let detail = try await client.productDetail(id: 7)

        #expect(detail.stockValue == nil)
        #expect(detail.lastPrice == nil)
        #expect(detail.averagePrice == nil)
        #expect(detail.currentPrice == nil)
        #expect(detail.stockAmount == 2)
    }

    @Test("A stock entry's price goes absent the same way")
    func stockEntryPriceAbsent() async throws {
        let redacted = """
            [{"id": 77, "product_id": 7, "amount": 1, "stock_id": "lot-1", "open": 0}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: redacted))

        let entry = try #require(try await client.stockEntries(productID: 7).first)

        #expect(entry.price == nil)
        #expect(entry.stockID == "lot-1")
    }
}

/// Dates, in both shapes the server renders them.
@Suite("Wire dates")
struct WireDateTests {
    @Test("A day parses, with or without the time suffix ADR-0005 documents")
    func parsesDays() {
        let plain = VictualDates.day("2026-01-31")
        let suffixed = VictualDates.day("2026-01-31 00:00:00")

        #expect(plain != nil)
        #expect(plain == suffixed)
        #expect(plain.map(VictualDates.string(fromDay:)) == "2026-01-31")
    }

    @Test("A day round-trips through the formatter unchanged")
    func roundTripsDays() throws {
        let parsed = try #require(VictualDates.day("2026-09-21"))
        #expect(VictualDates.string(fromDay: parsed) == "2026-09-21")
    }

    @Test("An absent or unparseable day is nil, not the epoch", arguments: [
        nil, "", "   ", "not a date", "31/01/2026",
    ] as [String?])
    func rejectsNonDates(text: String?) {
        #expect(VictualDates.day(text) == nil)
    }

    /// The server renders `row_created_timestamp` the way its database stores
    /// it, with a space and no offset. Until Victual 0.2.0-MVP the specification
    /// typed it `format: date-time`, and without a lenient reader every
    /// stock-entry read failed outright; it is now a patterned string, parsed at
    /// the mapping boundary by ``VictualDates/timestamp(_:)``.
    @Test("A timestamp in the server's own rendering decodes")
    func decodesDatabaseTimestamps() async throws {
        let body = """
            [{"id": 77, "stock_id": "s", "product_id": 7, "amount": 1,
              "row_created_timestamp": "2019-05-03 18:24:04"}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let entry = try #require(try await client.stockEntries(productID: 7).first)

        #expect(entry.createdAt != nil)
    }

    @Test("An ISO 8601 timestamp still decodes")
    func decodesISOTimestamps() async throws {
        let body = """
            [{"id": 77, "stock_id": "s", "product_id": 7,
              "row_created_timestamp": "2019-05-03T18:24:04Z"}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let entry = try #require(try await client.stockEntries(productID: 7).first)

        // The explicit `Z` is honoured as UTC rather than reinterpreted in the
        // local zone: the ISO 8601 reader runs before the zone-less fallback.
        let expected = ISO8601DateFormatter().date(from: "2019-05-03T18:24:04Z")
        #expect(entry.createdAt == expected)
    }

    @Test("db-changed-time decodes in the server's rendering")
    func decodesChangedTime() async throws {
        let body = #"{"changed_time": "2026-09-21 09:14:02"}"#
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let changed = try await client.databaseChangedTime()

        #expect(changed.timeIntervalSince1970 > 0)
    }

    @Test("Neither rendering leaves a garbage timestamp standing")
    func rejectsGarbageTimestamps() async throws {
        let body = #"[{"id": 77, "row_created_timestamp": "yesterday"}]"#
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let error = await #expect(throws: VictualError.self) {
            try await client.stockEntries(productID: 7)
        }
        guard case .decodingFailed = try #require(error) else {
            Issue.record("expected .decodingFailed, got \(String(describing: error))")
            return
        }
    }
}

@Suite("Stock reads")
struct StockReadTests {
    @Test("Maps the 0/1 integer flags a product ships to Bool")
    func mapsWireFlags() async throws {
        let body = """
            [{"product_id": 7, "amount": 1, "product": {
                "id": 7, "name": "Cookies", "qu_id_stock": 3, "min_stock_amount": 8,
                "no_own_stock": 0, "treat_opened_as_out_of_stock": 1,
                "should_not_be_frozen": 1, "move_on_open": 0
            }}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let product = try #require(try await client.currentStock().first?.product)

        #expect(product.hasNoOwnStock == false)
        #expect(product.treatsOpenedAsOutOfStock == true)
        #expect(product.shouldNotBeFrozen == true)
        #expect(product.movesOnOpen == false)
        #expect(product.minimumStockAmount == 8)
        #expect(product.name == "Cookies")
    }

    @Test("Drops a row with no product id rather than inventing one")
    func dropsUnidentifiableRows() async throws {
        let body = """
            [{"amount": 1}, {"product_id": 7, "amount": 2}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let stock = try await client.currentStock()

        #expect(stock.count == 1)
        #expect(stock.first?.productID == 7)
    }

    @Test("Volatile stock splits into the four buckets in one request")
    func mapsVolatileStock() async throws {
        let body = """
            {
              "due_products": [{"product_id": 1, "amount": 1}],
              "overdue_products": [{"product_id": 2, "amount": 1}, {"product_id": 3, "amount": 1}],
              "expired_products": [],
              "missing_products": [
                {"id": 9, "name": "Milk", "amount_missing": 2, "is_partly_in_stock": 1}
              ]
            }
            """
        let transport = StubTransport(status: 200, json: body)
        let client = VictualClient.stubbed(transport)

        let volatile = try await client.volatileStock(dueSoonDays: 3)

        #expect(volatile.due.count == 1)
        #expect(volatile.overdue.count == 2)
        #expect(volatile.expired.isEmpty)
        #expect(volatile.belowMinimum.first?.name == "Milk")
        #expect(volatile.belowMinimum.first?.isPartlyInStock == true)
        #expect(!volatile.isEmpty)

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.url.query?.contains("due_soon_days=3") == true)
    }

    @Test("Omitting the due-soon window leaves the instance's own default")
    func omitsDueSoonDays() async throws {
        let transport = StubTransport(status: 200, json: "{}")
        let client = VictualClient.stubbed(transport)

        _ = try await client.volatileStock()

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.url.query?.contains("due_soon_days") != true)
    }

    @Test("Capabilities resolve into the gates a UI needs")
    func mapsCapabilities() async throws {
        let body = """
            {"key_type": "mcp", "read_only": true,
             "permissions": ["STOCK_VIEW", "STOCK_CONSUME"]}
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let capabilities = try await client.capabilities()

        #expect(capabilities.keyType == "mcp")
        #expect(capabilities.isReadOnly)
        #expect(capabilities.allows(VictualPermission.stockConsume))
        // Held, but unusable: a read-only key refuses every write regardless.
        #expect(!capabilities.canWrite(VictualPermission.stockConsume))
        #expect(capabilities.obstacle(to: VictualPermission.stockConsume)?.isEmpty == false)
        #expect(!capabilities.allows(VictualPermission.stockPricesView))
    }

    @Test("A stock-entry read does not name a price in query[] or order")
    func neverSortsByPrice() async throws {
        let transport = StubTransport(status: 200, json: "[]")
        let client = VictualClient.stubbed(transport)

        _ = try await client.stockEntries(productID: 7, includeSubProducts: true)

        let sent = try #require(transport.recorder.requests.first)
        let query = sent.url.query ?? ""
        // Naming a price field in either is answered 400 rather than applied,
        // so the wrapper exposes neither parameter at all.
        #expect(!query.contains("order"))
        #expect(!query.contains("query"))
        #expect(query.contains("include_sub_products=true"))
    }

    @Test("A 200 carrying no product is a .notFound, not an empty detail")
    func rejectsEmptyProductDetail() async throws {
        let client = VictualClient.stubbed(StubTransport(status: 200, json: "{}"))

        await #expect(throws: VictualError.notFound) {
            try await client.productDetail(id: 7)
        }
    }
}

/// `GET /objects/{entity}`, which is read outside the generated client.
@Suite("Entity listings")
struct EntityListingTests {
    @Test("Quantity units keep the plural the generated union would discard")
    func decodesQuantityUnits() async throws {
        let body = """
            [{"id": 3, "name": "Pack", "name_plural": "Packs", "description": null,
              "row_created_timestamp": "2019-05-02 20:12:25"},
             {"id": 4, "name": "g", "name_plural": null}]
            """
        let transport = StubTransport(status: 200, json: body)
        let client = VictualClient.stubbed(transport)

        let units = try await client.quantityUnits()

        #expect(units.count == 2)
        #expect(units.first?.namePlural == "Packs")
        #expect(units.first?.name(for: 1) == "Pack")
        #expect(units.first?.name(for: 2) == "Packs")
        // No plural defined: the singular stands in rather than a guess.
        #expect(units.last?.name(for: 2) == "g")

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.request.path == "/objects/quantity_units")
        #expect(sent.request.headerFields[VictualAPIKey.headerName] == "test-key")
    }

    @Test("Location paths come from the depth-0 rows of the resolved view")
    func decodesLocationPaths() async throws {
        // A closure table: every (ancestor, descendant) pair, including the
        // depth-0 self-pairs. Only those carry a path worth keying by.
        let body = """
            [{"id": 1, "ancestor_location_id": 4, "descendant_location_id": 4,
              "depth": 0, "path": "Kitchen"},
             {"id": 1, "ancestor_location_id": 4, "descendant_location_id": 9,
              "depth": 1, "path": "Kitchen / Freezer"},
             {"id": 1, "ancestor_location_id": 9, "descendant_location_id": 9,
              "depth": 0, "path": "Kitchen / Freezer"}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let paths = try await client.locationPaths()

        #expect(paths == [4: "Kitchen", 9: "Kitchen / Freezer"])
    }

    @Test("Locations keep the parent the generated union would discard")
    func decodesLocations() async throws {
        let body = """
            [{"id": 9, "name": "Freezer", "description": "the cold one",
              "parent_location_id": 4}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let location = try #require(try await client.locations().first)

        #expect(location.name == "Freezer")
        #expect(location.parentID == 4)
        #expect(location.details == "the cold one")
        #expect(location.path == nil)
    }

    @Test("The tree merges names and paths, sorted by path")
    func buildsLocationTree() async throws {
        let transport = StubTransport { request, _, _, _ in
            let json: String
            if request.path?.contains("locations_resolved") == true {
                json = """
                    [{"descendant_location_id": 9, "depth": 0, "path": "Kitchen / Freezer"},
                     {"descendant_location_id": 4, "depth": 0, "path": "Kitchen"}]
                    """
            } else {
                json = """
                    [{"id": 9, "name": "Freezer", "parent_location_id": 4},
                     {"id": 4, "name": "Kitchen"},
                     {"id": 12, "name": "Garage"}]
                    """
            }
            return (
                HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                HTTPBody(json)
            )
        }
        let client = VictualClient.stubbed(transport)

        let tree = try await client.locationTree()

        #expect(tree.map { $0.name } == ["Garage", "Kitchen", "Freezer"])
        #expect(tree.first(where: { $0.id == 9 })?.path == "Kitchen / Freezer")
        // No resolved row: keeps a nil path and sorts by its own name.
        #expect(tree.first(where: { $0.id == 12 })?.path == nil)
    }

    @Test("A non-200 becomes the matching VictualError")
    func mapsEntityListingFailures() async throws {
        let client = VictualClient.stubbed(
            StubTransport(status: 403, json: #"{"error_message":"nope"}"#)
        )

        await #expect(throws: VictualError.forbidden) {
            try await client.quantityUnits()
        }
    }

    @Test("Custom middlewares still run on this route")
    func appliesMiddlewares() async throws {
        let transport = StubTransport(status: 200, json: "[]")
        let client = VictualClient(
            server: VictualServer(instanceURL: URL(string: "https://victual.test")!),
            apiKey: "test-key",
            transport: transport,
            middlewares: [HeaderStampingMiddleware()]
        )

        _ = try await client.quantityUnits()

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.request.headerFields[.userAgent] == "victual-kit-test")
    }
}
