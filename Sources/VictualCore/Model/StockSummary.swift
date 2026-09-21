import Foundation
import VictualAPI

/// One product's line in the stock list.
///
/// ## Prices are read by presence
///
/// ``value`` is `nil` when the authenticating key's owner lacks
/// `STOCK_PRICES_VIEW`, because the server omits the field entirely rather than
/// sending null. It is never defaulted to zero: arithmetic over a missing price
/// would produce `NaN`, and a zero would be a claim about what the household
/// paid. Render it as an em dash, or leave the column out.
///
/// For the same reason, `value` must never be named in a `query[]` filter or an
/// `order` parameter — the server answers `400` rather than applying it.
public struct StockSummary: Hashable, Sendable, Identifiable {
    /// The product this row is about. Also the row's identity: `GET /stock`
    /// returns one row per product.
    public var productID: Int
    public var id: Int { productID }

    /// The amount in stock, in the product's stock quantity unit.
    public var amount: Double

    /// The amount including sub-products, filled only when
    /// ``isAggregatedAmount`` is true.
    public var amountAggregated: Double?

    /// How much of ``amount`` is in opened containers.
    public var amountOpened: Double

    public var amountOpenedAggregated: Double?

    /// The total value of this product's stock, or `nil` when the key's owner
    /// may not see prices. Never zero-filled — see the type's discussion.
    public var value: Double?

    /// The next date any of this product's stock is due.
    public var nextDueDate: Date?

    /// Whether this product has sub-products, and so whether the aggregated
    /// amounts are filled.
    public var isAggregatedAmount: Bool

    /// The product itself, as `GET /stock` embeds it.
    public var product: ProductSummary?

    /// The product's name, or a placeholder naming the id when the row arrived
    /// without an embedded product.
    public var displayName: String {
        product.map { $0.name.isEmpty ? "Product \(productID)" : $0.name }
            ?? "Product \(productID)"
    }

    public init(
        productID: Int,
        amount: Double = 0,
        amountAggregated: Double? = nil,
        amountOpened: Double = 0,
        amountOpenedAggregated: Double? = nil,
        value: Double? = nil,
        nextDueDate: Date? = nil,
        isAggregatedAmount: Bool = false,
        product: ProductSummary? = nil
    ) {
        self.productID = productID
        self.amount = amount
        self.amountAggregated = amountAggregated
        self.amountOpened = amountOpened
        self.amountOpenedAggregated = amountOpenedAggregated
        self.value = value
        self.nextDueDate = nextDueDate
        self.isAggregatedAmount = isAggregatedAmount
        self.product = product
    }
}

extension StockSummary {
    /// Fails when the row carries no `product_id`, which would leave nothing to
    /// address a booking to.
    init?(_ schema: Components.Schemas.CurrentStockResponse) {
        guard let productID = schema.productId else { return nil }
        self.init(
            productID: productID,
            amount: schema.amount ?? 0,
            amountAggregated: schema.amountAggregated,
            amountOpened: schema.amountOpened ?? 0,
            amountOpenedAggregated: schema.amountOpenedAggregated,
            // Straight across, deliberately: absent stays absent.
            value: schema.value,
            nextDueDate: VictualDates.day(schema.bestBeforeDate),
            isAggregatedAmount: schema.isAggregatedAmount ?? false,
            product: schema.product.flatMap(ProductSummary.init)
        )
    }
}

/// A product the server reports as below its configured minimum.
///
/// `missing_products` is deliberately not a stock row: it carries only these
/// four fields, so a view over ``StockFilter/belowMinimum`` has less to show
/// than the other buckets.
public struct MissingProduct: Hashable, Sendable, Identifiable {
    /// The product id.
    public var id: Int
    public var name: String
    /// How much short of the minimum the product is.
    public var amountMissing: Double
    /// Whether some of the product is in stock, just not enough of it.
    public var isPartlyInStock: Bool

    public init(id: Int, name: String, amountMissing: Double = 0, isPartlyInStock: Bool = false) {
        self.id = id
        self.name = name
        self.amountMissing = amountMissing
        self.isPartlyInStock = isPartlyInStock
    }
}

extension MissingProduct {
    init?(_ schema: Components.Schemas.CurrentVolatilStockResponse.MissingProductsPayloadPayload) {
        guard let id = schema.id else { return nil }
        self.init(
            id: id,
            name: schema.name ?? "Product \(id)",
            amountMissing: schema.amountMissing ?? 0,
            isPartlyInStock: .fromWireFlag(schema.isPartlyInStock)
        )
    }
}

/// The four attention buckets, as `GET /stock/volatile` returns them together.
///
/// One request answers four of ``StockFilter``'s five cases, which is why a
/// sidebar with five entries costs two requests rather than five.
public struct VolatileStock: Hashable, Sendable {
    /// Due within the window the request asked for.
    public var due: [StockSummary]
    /// Past due but not yet treated as expired.
    public var overdue: [StockSummary]
    /// Past due and expired.
    public var expired: [StockSummary]
    /// Below the product's configured minimum stock amount.
    public var belowMinimum: [MissingProduct]

    public init(
        due: [StockSummary] = [],
        overdue: [StockSummary] = [],
        expired: [StockSummary] = [],
        belowMinimum: [MissingProduct] = []
    ) {
        self.due = due
        self.overdue = overdue
        self.expired = expired
        self.belowMinimum = belowMinimum
    }

    /// Whether every bucket is empty — nothing needs attention.
    public var isEmpty: Bool {
        due.isEmpty && overdue.isEmpty && expired.isEmpty && belowMinimum.isEmpty
    }
}

extension VolatileStock {
    init(_ schema: Components.Schemas.CurrentVolatilStockResponse) {
        self.init(
            due: (schema.dueProducts ?? []).compactMap(StockSummary.init),
            overdue: (schema.overdueProducts ?? []).compactMap(StockSummary.init),
            expired: (schema.expiredProducts ?? []).compactMap(StockSummary.init),
            belowMinimum: (schema.missingProducts ?? []).compactMap(MissingProduct.init)
        )
    }
}
