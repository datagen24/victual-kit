import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualTestSupport

@testable import VictualCore

@Suite("Catalog reads")
struct CatalogReadTests {
    @Test("A filter goes out as query[] with the condition percent-encoded")
    func queryIsEncoded() async throws {
        let transport = StubTransport(status: 200, json: "[]")
        let client = VictualClient.stubbed(transport)

        _ = try await client.unitConversions(productID: 17)

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.url.path.hasSuffix("/objects/quantity_unit_conversions_resolved"))
        #expect(sent.url.absoluteString.hasSuffix("?query%5B%5D=product_id%3D17"))
    }

    @Test("An entity read without a filter has no query string")
    func noQueryNoQuestionMark() async throws {
        let transport = StubTransport(status: 200, json: "[]")
        _ = try await VictualClient.stubbed(transport).products()
        #expect(try #require(transport.recorder.requests.first).url.query == nil)
    }

    @Test("Several conditions repeat query[]")
    func severalConditions() {
        #expect(VictualClient.queryString(["a=1", "b~x y"]) == "?query%5B%5D=a%3D1&query%5B%5D=b~x%20y")
    }

    @Test("A conversion factor may arrive as a number or as text")
    func factorShapes() async throws {
        let body = """
            [{"product_id": 17, "from_qu_id": 2, "to_qu_id": 1, "factor": 30},
             {"product_id": 17, "from_qu_id": 3, "to_qu_id": 1, "factor": "2.5"}]
            """
        let rows = try await VictualClient.stubbed(StubTransport(status: 200, json: body)).unitConversions(productID: 17)
        #expect(rows.map(\.factor) == [30, 2.5])
        #expect(rows.map(\.fromUnitID) == [2, 3])
    }

    @Test("A product listing carries its stock unit")
    func productListing() async throws {
        let body = #"[{"id": 17, "name": "Vitamin", "qu_id_stock": 4, "min_stock_amount": 0}]"#
        let rows = try await VictualClient.stubbed(StubTransport(status: 200, json: body)).products()
        #expect(rows == [ProductListing(id: 17, name: "Vitamin", stockUnitID: 4)])
    }

    @Test("Product locations read the stock route")
    func productLocations() async throws {
        let body = #"[{"id": 1, "product_id": 17, "amount": 3, "location_id": 9, "location_name": "Organizer"}]"#
        let transport = StubTransport(status: 200, json: body)
        let rows = try await VictualClient.stubbed(transport).productLocations(productID: 17)
        #expect(rows == [ProductLocation(locationID: 9, name: "Organizer")])
        #expect(try #require(transport.recorder.requests.first).url.path.hasSuffix("/stock/products/17/locations"))
    }
}
