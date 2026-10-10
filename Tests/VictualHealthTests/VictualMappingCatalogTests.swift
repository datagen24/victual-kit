import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualCore
import VictualTestSupport
@testable import VictualHealth

@Suite("Real mapping catalog")
struct VictualMappingCatalogTests {
    private func client(locationsHoldingProduct: String = "[]") -> VictualClient {
        VictualClient.stubbed(
            StubTransport { request, _, _, _ in
                let path = request.path ?? ""
                let json: String
                if path.contains("/objects/products") {
                    json = #"[{"id": 17, "name": "Vitamin D", "qu_id_stock": 1}]"#
                } else if path.contains("quantity_unit_conversions_resolved") {
                    json = """
                        [{"product_id": 17, "from_qu_id": 2, "to_qu_id": 1, "factor": 30},
                         {"product_id": 17, "from_qu_id": 1, "to_qu_id": 2, "factor": 0.0333},
                         {"product_id": 17, "from_qu_id": 3, "to_qu_id": 9, "factor": 5}]
                        """
                } else if path.contains("/objects/quantity_units") {
                    json = #"[{"id": 1, "name": "tablet"}, {"id": 2, "name": "bottle"}, {"id": 3, "name": "x"}]"#
                } else if path.contains("/consumption/recipes") {
                    json = #"[{"id": 4, "name": "Morning", "rights": {"consume": true}}, {"id": 5, "name": "Read only", "rights": {"consume": false}}]"#
                } else if path.contains("/stock/products/17/locations") {
                    json = locationsHoldingProduct
                } else if path.contains("/objects/locations_resolved") {
                    json = #"[{"id": 1, "ancestor_location_id": 5, "descendant_location_id": 5, "depth": 0, "path": "Shelf"},{"id": 1, "ancestor_location_id": 6, "descendant_location_id": 6, "depth": 0, "path": "Organizer"}]"#
                } else if path.contains("/objects/locations") {
                    json = #"[{"id": 5, "name": "Shelf"}, {"id": 6, "name": "Organizer"}]"#
                } else {
                    json = "[]"
                }
                return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(json))
            })
    }

    @Test func unitsAreTheStockUnitAndConversionsIntoIt() async throws {
        let units = try await VictualMappingCatalog(client: client()).units(forProduct: 17)
        #expect(units.map(\.name) == ["tablet", "bottle"])
        #expect(units.map(\.factorToStockUnit) == [1, 30])
    }

    @Test func productsAreSortedAndNamed() async throws {
        let products = try await VictualMappingCatalog(client: client()).products()
        #expect(products == [CatalogItem(id: 17, name: "Vitamin D")])
    }

    @Test func recipesAreConsumptionRecipesTheCallerMayConsume() async throws {
        #expect(try await VictualMappingCatalog(client: client()).recipes() == [CatalogItem(id: 4, name: "Morning")])
    }

    @Test func locationsPreferWhereTheProductIs() async throws {
        let holding = #"[{"id": 1, "product_id": 17, "amount": 3, "location_id": 6, "location_name": "Organizer"}]"#
        let locations = try await VictualMappingCatalog(client: client(locationsHoldingProduct: holding)).locations(forProduct: 17)
        #expect(locations.map(\.id) == [6])
    }

    @Test func aProductWithNoStockOffersEveryLocation() async throws {
        let locations = try await VictualMappingCatalog(client: client()).locations(forProduct: 17)
        #expect(Set(locations.map(\.id)) == [5, 6])
    }
}
