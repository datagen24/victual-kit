import Foundation
import VictualAPI

/// A product as the catalog lists it: enough to choose one and to know its stock unit.
public struct ProductListing: Hashable, Sendable, Identifiable, Codable {
    public var id: Int
    public var name: String
    /// The unit the product's stock is counted in.
    public var stockUnitID: Int

    public init(id: Int, name: String, stockUnitID: Int) {
        self.id = id
        self.name = name
        self.stockUnitID = stockUnitID
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case stockUnitID = "qu_id_stock"
    }
}

/// One row of `quantity_unit_conversions_resolved` for a product: `factor` of the
/// `to` unit make one of the `from` unit.
public struct QuantityUnitConversion: Hashable, Sendable, Codable {
    public var productID: Int?
    public var fromUnitID: Int
    public var toUnitID: Int
    public var factor: Double

    public init(productID: Int?, fromUnitID: Int, toUnitID: Int, factor: Double) {
        self.productID = productID
        self.fromUnitID = fromUnitID
        self.toUnitID = toUnitID
        self.factor = factor
    }

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case fromUnitID = "from_qu_id"
        case toUnitID = "to_qu_id"
        case factor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productID = try container.decodeIfPresent(Int.self, forKey: .productID)
        fromUnitID = try container.decode(Int.self, forKey: .fromUnitID)
        toUnitID = try container.decode(Int.self, forKey: .toUnitID)
        // The resolved view caches `factor` as text on some engines, so it arrives
        // as a number or as a string holding one.
        if let number = try? container.decode(Double.self, forKey: .factor) {
            factor = number
        } else if let text = try? container.decode(String.self, forKey: .factor), let number = Double(text) {
            factor = number
        } else {
            throw DecodingError.dataCorruptedError(forKey: .factor, in: container, debugDescription: "Not a number")
        }
    }
}

/// A place that holds a product, from `GET /stock/products/{id}/locations`.
public struct ProductLocation: Hashable, Sendable, Codable {
    public var locationID: Int
    public var name: String

    public init(locationID: Int, name: String) {
        self.locationID = locationID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case locationID = "location_id"
        case name = "location_name"
    }
}

/// Reads for choosing what to map a medication to.
///
/// All under `STOCK_VIEW`, and all existing routes (ADR-0041 §"mapping screen").
extension VictualClient {
    /// Every product, including those with no stock: a medication's product may
    /// be empty.
    public func products() async throws(VictualError) -> [ProductListing] {
        do {
            return try await listObjects("products", as: ProductListing.self)
        } catch {
            throw VictualError.mapping(error)
        }
    }

    /// One product, or `nil` if there is none with that id.
    public func product(id: Int) async throws(VictualError) -> ProductListing? {
        do {
            return try await listObjects("products", as: ProductListing.self, query: ["id=\(id)"]).first
        } catch {
            throw VictualError.mapping(error)
        }
    }

    /// The unit conversions that apply to `productID`, including the product's own.
    public func unitConversions(productID: Int) async throws(VictualError) -> [QuantityUnitConversion] {
        do {
            return try await listObjects(
                "quantity_unit_conversions_resolved", as: QuantityUnitConversion.self,
                query: ["product_id=\(productID)"])
        } catch {
            throw VictualError.mapping(error)
        }
    }

    /// The locations that hold stock of `productID`.
    public func productLocations(productID: Int) async throws(VictualError) -> [ProductLocation] {
        try await perform {
            try await underlying.getStockProductsByProductIdLocations(.init(path: .init(productId: productID)))
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return try response.body.json.compactMap { row in
                    guard let id = row.locationId else { return nil }
                    return ProductLocation(locationID: id, name: row.locationName ?? "")
                }
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }
}
