import Foundation
import VictualAPI

/// A product, as much of it as a stock list or a product inspector needs.
///
/// Mapped from both `Product` and `ProductWithoutUserfields`, which carry the
/// same columns and differ only in whether userfields ride along. Neither is
/// visible outside ``VictualCore``.
public struct ProductSummary: Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var details: String?
    public var locationID: Int?
    public var shoppingLocationID: Int?
    public var productGroupID: Int?
    public var defaultConsumeLocationID: Int?

    /// The unit stock is counted in. Amounts are meaningless without it.
    public var stockQuantityUnitID: Int?
    public var purchaseQuantityUnitID: Int?

    /// The amount below which the product is reported as missing.
    public var minimumStockAmount: Double
    public var defaultBestBeforeDays: Int?
    public var defaultBestBeforeDaysAfterOpen: Int?
    public var pictureFileName: String?

    // The wire ships these as `integer` 0/1. They become `Bool` here, once, so
    // no view has to remember that `1` means true.
    public var treatsOpenedAsOutOfStock: Bool
    public var hasNoOwnStock: Bool
    public var shouldNotBeFrozen: Bool
    public var movesOnOpen: Bool
    public var autoReprintsStockLabel: Bool
    public var skipsStockFulfillmentCheckForRecipes: Bool

    public init(
        id: Int,
        name: String,
        details: String? = nil,
        locationID: Int? = nil,
        shoppingLocationID: Int? = nil,
        productGroupID: Int? = nil,
        defaultConsumeLocationID: Int? = nil,
        stockQuantityUnitID: Int? = nil,
        purchaseQuantityUnitID: Int? = nil,
        minimumStockAmount: Double = 0,
        defaultBestBeforeDays: Int? = nil,
        defaultBestBeforeDaysAfterOpen: Int? = nil,
        pictureFileName: String? = nil,
        treatsOpenedAsOutOfStock: Bool = false,
        hasNoOwnStock: Bool = false,
        shouldNotBeFrozen: Bool = false,
        movesOnOpen: Bool = false,
        autoReprintsStockLabel: Bool = false,
        skipsStockFulfillmentCheckForRecipes: Bool = false
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.locationID = locationID
        self.shoppingLocationID = shoppingLocationID
        self.productGroupID = productGroupID
        self.defaultConsumeLocationID = defaultConsumeLocationID
        self.stockQuantityUnitID = stockQuantityUnitID
        self.purchaseQuantityUnitID = purchaseQuantityUnitID
        self.minimumStockAmount = minimumStockAmount
        self.defaultBestBeforeDays = defaultBestBeforeDays
        self.defaultBestBeforeDaysAfterOpen = defaultBestBeforeDaysAfterOpen
        self.pictureFileName = pictureFileName
        self.treatsOpenedAsOutOfStock = treatsOpenedAsOutOfStock
        self.hasNoOwnStock = hasNoOwnStock
        self.shouldNotBeFrozen = shouldNotBeFrozen
        self.movesOnOpen = movesOnOpen
        self.autoReprintsStockLabel = autoReprintsStockLabel
        self.skipsStockFulfillmentCheckForRecipes = skipsStockFulfillmentCheckForRecipes
    }
}

extension ProductSummary {
    /// Maps the shape `GET /stock` embeds in each row.
    ///
    /// Fails when the row has no `id`: every action this application offers
    /// addresses a product by id, so a row without one cannot be shown or acted
    /// on. The wrappers drop such rows rather than inventing a placeholder.
    init?(_ schema: Components.Schemas.ProductWithoutUserfields) {
        guard let id = schema.id else { return nil }
        self.init(
            id: id,
            name: schema.name ?? "",
            details: schema.description,
            locationID: schema.locationId,
            shoppingLocationID: schema.shoppingLocationId,
            productGroupID: schema.productGroupId,
            defaultConsumeLocationID: schema.defaultConsumeLocationId,
            stockQuantityUnitID: schema.quIdStock,
            purchaseQuantityUnitID: schema.quIdPurchase,
            minimumStockAmount: schema.minStockAmount ?? 0,
            defaultBestBeforeDays: schema.defaultBestBeforeDays,
            defaultBestBeforeDaysAfterOpen: schema.defaultBestBeforeDaysAfterOpen,
            pictureFileName: schema.pictureFileName,
            treatsOpenedAsOutOfStock: .fromWireFlag(schema.treatOpenedAsOutOfStock),
            hasNoOwnStock: .fromWireFlag(schema.noOwnStock),
            shouldNotBeFrozen: .fromWireFlag(schema.shouldNotBeFrozen),
            movesOnOpen: .fromWireFlag(schema.moveOnOpen),
            autoReprintsStockLabel: .fromWireFlag(schema.autoReprintStockLabel),
            skipsStockFulfillmentCheckForRecipes:
                .fromWireFlag(schema.notCheckStockFulfillmentForRecipes)
        )
    }

    /// Maps the shape `GET /stock/products/{id}` returns, which is the same
    /// columns with userfields attached.
    init?(_ schema: Components.Schemas.Product) {
        guard let id = schema.id else { return nil }
        self.init(
            id: id,
            name: schema.name ?? "",
            details: schema.description,
            locationID: schema.locationId,
            shoppingLocationID: schema.shoppingLocationId,
            productGroupID: schema.productGroupId,
            defaultConsumeLocationID: schema.defaultConsumeLocationId,
            stockQuantityUnitID: schema.quIdStock,
            purchaseQuantityUnitID: schema.quIdPurchase,
            minimumStockAmount: schema.minStockAmount ?? 0,
            defaultBestBeforeDays: schema.defaultBestBeforeDays,
            defaultBestBeforeDaysAfterOpen: schema.defaultBestBeforeDaysAfterOpen,
            pictureFileName: schema.pictureFileName,
            treatsOpenedAsOutOfStock: .fromWireFlag(schema.treatOpenedAsOutOfStock),
            hasNoOwnStock: .fromWireFlag(schema.noOwnStock),
            shouldNotBeFrozen: .fromWireFlag(schema.shouldNotBeFrozen),
            movesOnOpen: .fromWireFlag(schema.moveOnOpen),
            autoReprintsStockLabel: .fromWireFlag(schema.autoReprintStockLabel),
            skipsStockFulfillmentCheckForRecipes:
                .fromWireFlag(schema.notCheckStockFulfillmentForRecipes)
        )
    }
}

extension Bool {
    /// Reads one of the API's `integer` 0/1 flags.
    ///
    /// Absent is false, which is what the columns default to server-side. Any
    /// non-zero value is true rather than only `1`, because the column is an
    /// integer and nothing promises it is only ever 0 or 1.
    static func fromWireFlag(_ value: Int?) -> Bool {
        (value ?? 0) != 0
    }
}
