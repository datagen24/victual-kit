import Foundation
import VictualAPI
import VictualCore

/// The mapping editor's choices, read from a real Victual instance.
///
/// Everything here is an existing route under `STOCK_VIEW`: the product list,
/// `quantity_unit_conversions_resolved` filtered to one product, and the
/// locations that hold it. It reads and never writes, so it needs none of the
/// medication routes and works against Victual 0.3.x.
///
/// Recipes are the caller's **consumption recipes** (`GET /consumption/recipes`),
/// not food recipes: ADR-0040 keeps them in a separate, owned list. Only a recipe the
/// caller holds the `consume` right on is offered, since a mapping to any other would
/// book nothing.
public struct VictualMappingCatalog: MappingCatalog {
    private let client: VictualClient

    public init(client: VictualClient) {
        self.client = client
    }

    public func products() async throws -> [CatalogItem] {
        try await client.products()
            .map { CatalogItem(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func recipes() async throws -> [CatalogItem] {
        let response = try await client.send(.get, path: "/consumption/recipes", operationID: "listConsumptionRecipes")
        let recipes = try client.decode([Components.Schemas.ConsumptionRecipeSummary].self, from: response.data)
        return recipes.compactMap { recipe in
            guard let id = recipe.id, let name = recipe.name, recipe.rights?.consume != false else { return nil }
            return CatalogItem(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The product's stock unit at factor 1, then every unit with a conversion into it.
    public func units(forProduct id: Int) async throws -> [CatalogUnit] {
        guard let product = try await client.product(id: id) else { throw VictualError.notFound }
        async let conversions = client.unitConversions(productID: id)
        async let units = client.quantityUnits()
        let names = Dictionary(try await units.map { ($0.id, $0.name) }) { first, _ in first }

        var result = [CatalogUnit(id: product.stockUnitID, name: names[product.stockUnitID] ?? "Unit \(product.stockUnitID)", factorToStockUnit: 1, isStockUnit: true)]
        var seen: Set<Int> = [product.stockUnitID]
        for conversion in try await conversions
        where conversion.toUnitID == product.stockUnitID && conversion.factor > 0 && !seen.contains(conversion.fromUnitID) {
            seen.insert(conversion.fromUnitID)
            result.append(
                CatalogUnit(
                    id: conversion.fromUnitID, name: names[conversion.fromUnitID] ?? "Unit \(conversion.fromUnitID)",
                    factorToStockUnit: conversion.factor, isStockUnit: false))
        }
        return result
    }

    /// The locations holding the product; every location when none does, or when
    /// `id` is `nil`. A product with no stock yet still needs an organizer to be chosen.
    public func locations(forProduct id: Int?) async throws -> [CatalogLocation] {
        let all = try await client.locationTree()
        let name: (StorageLocation) -> String = { $0.path ?? $0.displayName }
        if let id {
            let holding = Set(try await client.productLocations(productID: id).map(\.locationID))
            let matching = all.filter { holding.contains($0.id) }
            if !matching.isEmpty { return matching.map { CatalogLocation(id: $0.id, name: name($0)) } }
        }
        return all.map { CatalogLocation(id: $0.id, name: name($0)) }
    }
}
