import Foundation
import VictualAPI

/// Everything `GET /stock/products/{id}` reports about one product.
///
/// Four of its fields are price-bearing — ``stockValue``, ``lastPrice``,
/// ``averagePrice`` and ``currentPrice`` — and all four are `nil` when the
/// authenticating key's owner lacks `STOCK_PRICES_VIEW`. None is ever
/// zero-filled.
public struct ProductDetail: Hashable, Sendable, Identifiable {
    public var product: ProductSummary
    public var id: Int { product.id }

    /// The amount in stock, in ``stockQuantityUnit``.
    public var stockAmount: Double
    /// How much of ``stockAmount`` is in opened containers.
    public var stockAmountOpened: Double
    /// The measured — not merely counted — contents of opened, measured
    /// containers. Kept separate from the two amounts above rather than folded
    /// into them.
    public var stockAmountMeasured: Double?

    /// The value of the stock held, or `nil` without `STOCK_PRICES_VIEW`.
    public var stockValue: Double?
    /// The price of the most recent purchase, or `nil` without the permission.
    public var lastPrice: Double?
    /// The average price across stock currently held, or `nil` without it.
    public var averagePrice: Double?
    /// The price of the entry that would be consumed next, or `nil` without it.
    public var currentPrice: Double?

    public var nextDueDate: Date?
    public var lastPurchased: Date?
    public var lastUsed: Date?

    /// The unit stock is counted in. Without it an amount cannot be rendered.
    public var stockQuantityUnit: QuantityUnit?
    public var purchaseQuantityUnit: QuantityUnit?
    public var consumeQuantityUnit: QuantityUnit?
    public var priceQuantityUnit: QuantityUnit?

    /// Where the stock actually is.
    public var location: StorageLocation?
    /// Where new stock lands when a purchase names no location.
    public var defaultLocation: StorageLocation?

    public var lastShoppingLocationID: Int?
    public var averageShelfLifeDays: Double?
    public var spoilRatePercent: Double?

    /// Whether this product is a parent of others, which is what makes
    /// sub-product substitution meaningful on a booking.
    public var hasChildProducts: Bool

    public init(
        product: ProductSummary,
        stockAmount: Double = 0,
        stockAmountOpened: Double = 0,
        stockAmountMeasured: Double? = nil,
        stockValue: Double? = nil,
        lastPrice: Double? = nil,
        averagePrice: Double? = nil,
        currentPrice: Double? = nil,
        nextDueDate: Date? = nil,
        lastPurchased: Date? = nil,
        lastUsed: Date? = nil,
        stockQuantityUnit: QuantityUnit? = nil,
        purchaseQuantityUnit: QuantityUnit? = nil,
        consumeQuantityUnit: QuantityUnit? = nil,
        priceQuantityUnit: QuantityUnit? = nil,
        location: StorageLocation? = nil,
        defaultLocation: StorageLocation? = nil,
        lastShoppingLocationID: Int? = nil,
        averageShelfLifeDays: Double? = nil,
        spoilRatePercent: Double? = nil,
        hasChildProducts: Bool = false
    ) {
        self.product = product
        self.stockAmount = stockAmount
        self.stockAmountOpened = stockAmountOpened
        self.stockAmountMeasured = stockAmountMeasured
        self.stockValue = stockValue
        self.lastPrice = lastPrice
        self.averagePrice = averagePrice
        self.currentPrice = currentPrice
        self.nextDueDate = nextDueDate
        self.lastPurchased = lastPurchased
        self.lastUsed = lastUsed
        self.stockQuantityUnit = stockQuantityUnit
        self.purchaseQuantityUnit = purchaseQuantityUnit
        self.consumeQuantityUnit = consumeQuantityUnit
        self.priceQuantityUnit = priceQuantityUnit
        self.location = location
        self.defaultLocation = defaultLocation
        self.lastShoppingLocationID = lastShoppingLocationID
        self.averageShelfLifeDays = averageShelfLifeDays
        self.spoilRatePercent = spoilRatePercent
        self.hasChildProducts = hasChildProducts
    }
}

extension ProductDetail {
    /// Fails when the response carried no usable product, which is the only part
    /// of it the rest is about.
    init?(_ schema: Components.Schemas.ProductDetailsResponse) {
        guard let product = schema.product.flatMap(ProductSummary.init) else { return nil }
        self.init(
            product: product,
            stockAmount: schema.stockAmount ?? 0,
            stockAmountOpened: schema.stockAmountOpened ?? 0,
            stockAmountMeasured: schema.stockAmountMeasured,
            // The four price fields cross straight over: absent stays absent.
            stockValue: schema.stockValue,
            lastPrice: schema.lastPrice,
            averagePrice: schema.avgPrice,
            currentPrice: schema.currentPrice,
            nextDueDate: VictualDates.day(schema.nextDueDate),
            lastPurchased: VictualDates.day(schema.lastPurchased),
            lastUsed: VictualDates.day(schema.lastUsed),
            stockQuantityUnit: schema.quantityUnitStock.flatMap(QuantityUnit.init),
            purchaseQuantityUnit: schema.defaultQuantityUnitPurchase.flatMap(QuantityUnit.init),
            consumeQuantityUnit: schema.defaultQuantityUnitConsume.flatMap(QuantityUnit.init),
            priceQuantityUnit: schema.quantityUnitPrice.flatMap(QuantityUnit.init),
            location: schema.location.flatMap(StorageLocation.init),
            defaultLocation: schema.defaultLocation.flatMap(StorageLocation.init),
            lastShoppingLocationID: schema.lastShoppingLocationId,
            averageShelfLifeDays: schema.averageShelfLifeDays,
            spoilRatePercent: schema.spoilRatePercent,
            hasChildProducts: schema.hasChilds ?? false
        )
    }
}
