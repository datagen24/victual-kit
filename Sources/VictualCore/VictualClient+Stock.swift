import Foundation
import VictualAPI

/// The reads a stock front end needs, in the shape the rest of the package
/// expects: a generated call in, a domain value out, every failure a
/// ``VictualError``.
///
/// Nothing under `Components.Schemas.` crosses out of this file. That is the
/// point of it: when the next specification re-sync renames a generated symbol,
/// this file stops compiling and the user interface does not change at all.
extension VictualClient {
    /// Products currently in stock, with the next due date and amount for each.
    ///
    /// Requires `STOCK_VIEW`. Rows the server sends without a `product_id` are
    /// dropped — nothing could be shown for them and no booking could address
    /// them.
    ///
    /// Each row's `value` is `nil` for a caller without `STOCK_PRICES_VIEW`;
    /// see ``StockSummary`` for why that is not a zero.
    public func currentStock() async throws(VictualError) -> [StockSummary] {
        try await perform {
            try await underlying.getCurrentStock(.init())
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return try response.body.json.compactMap(StockSummary.init)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Everything needing attention, in one request.
    ///
    /// Due, overdue, expired and below-minimum arrive together, which is what
    /// lets a five-entry sidebar cost two requests rather than five.
    ///
    /// - Parameter dueSoonDays: How many days ahead count as due soon. The
    ///   window is a property of the request, not of the product, so two clients
    ///   may disagree about "soon" without either being wrong. `nil` leaves the
    ///   instance's own default, which is 5.
    public func volatileStock(
        dueSoonDays: Int? = nil
    ) async throws(VictualError) -> VolatileStock {
        try await perform {
            try await underlying.getVolatileStock(
                .init(query: .init(dueSoonDays: dueSoonDays))
            )
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return VolatileStock(try response.body.json)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Everything the server reports about one product.
    ///
    /// The four price-bearing fields are `nil` without `STOCK_PRICES_VIEW`.
    public func productDetail(id: Int) async throws(VictualError) -> ProductDetail {
        try await perform {
            try await underlying.getStockProductsByProductId(.init(path: .init(productId: id)))
        } unwrap: { output in
            switch output {
            case .ok(let response):
                guard let detail = ProductDetail(try response.body.json) else {
                    // A 200 that carries no product is not a product detail.
                    throw VictualError.notFound
                }
                return detail
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// The individual lots making up a product's stock.
    ///
    /// - Parameters:
    ///   - productID: The product to list entries for.
    ///   - includeSubProducts: Whether to include the entries of this product's
    ///     children, in addition to its own. Only meaningful for a parent
    ///     product.
    ///
    /// Each entry's `price` is `nil` without `STOCK_PRICES_VIEW`. Note that the
    /// route accepts `query[]` and `order`, and this wrapper deliberately does
    /// not expose them: naming a price field in either is answered `400` rather
    /// than applied, so sorting and filtering belong in the store, over values
    /// already fetched.
    public func stockEntries(
        productID: Int,
        includeSubProducts: Bool = false
    ) async throws(VictualError) -> [StockEntry] {
        try await perform {
            try await underlying.getStockProductsByProductIdEntries(
                .init(
                    path: .init(productId: productID),
                    query: .init(includeSubProducts: includeSubProducts)
                )
            )
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return try response.body.json.compactMap(StockEntry.init)
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// The individual lots actually sitting in one location.
    ///
    /// This is what a locations sidebar should be built on. `GET /stock` reports
    /// a product's *default* location, which is where new stock lands rather
    /// than where the stock on hand is; the two differ as soon as anything is
    /// transferred.
    public func stockEntries(locationID: Int) async throws(VictualError) -> [StockEntry] {
        try await perform {
            try await underlying.getStockLocationsByLocationIdEntries(
                .init(path: .init(locationId: locationID))
            )
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return try response.body.json.compactMap(StockEntry.init)
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// What the authenticating key's owner is allowed to do.
    ///
    /// This is the endpoint to ask about the acting user. `GET /user` is not
    /// usable: upstream types its 200 response as an object carrying `items`,
    /// which is meaningless on an object, so it generates as a free-form
    /// container rather than a user. That is recorded in
    /// `openapi/spec-lock.json` under `upstreamIssuesLeftInPlace`.
    public func capabilities() async throws(VictualError) -> VictualCapabilities {
        try await perform {
            try await underlying.getUserCapabilities(.init())
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return VictualCapabilities(try response.body.json)
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// When the instance's database last changed.
    ///
    /// Polling this and refreshing only when it moves is much cheaper than
    /// re-fetching `/stock` on a timer.
    public func databaseChangedTime() async throws(VictualError) -> Date {
        try await perform {
            try await underlying.getDatabaseChangedTime(.init())
        } unwrap: { output in
            switch output {
            case .ok(let response):
                guard let changed = try response.body.json.changedTime else {
                    throw VictualError.decodingFailed(underlying: MissingChangedTime())
                }
                return changed
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }
}

/// `GET /system/db-changed-time` answered without the timestamp it exists to
/// report.
struct MissingChangedTime: Error, LocalizedError {
    var errorDescription: String? {
        "The server did not report when its database last changed."
    }
}
