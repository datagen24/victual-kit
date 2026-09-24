import Foundation
import VictualAPI

/// One physical lot of a product: an amount bought at one time, with one due
/// date, in one location.
///
/// A booking that names a specific entry uses ``stockID``, not ``id`` — the
/// API's `stock_entry_id` is the string that follows a lot through its lifetime.
public struct StockEntry: Hashable, Sendable, Identifiable {
    /// The row id.
    public var id: Int

    /// The identifier a booking passes as `stock_entry_id`.
    ///
    /// `nil` only if the server omitted it, in which case this entry cannot be
    /// booked individually.
    public var stockID: String?

    public var productID: Int?
    public var locationID: Int?
    public var shoppingLocationID: Int?

    /// How much of the product this lot holds, in the product's stock unit.
    public var amount: Double

    public var bestBeforeDate: Date?
    public var purchasedDate: Date?
    public var openedDate: Date?

    /// What this lot cost per stock unit, or `nil` when the key's owner may not
    /// see prices. Never zero-filled.
    public var price: Double?

    /// Whether the container has been opened.
    public var isOpen: Bool

    public var note: String?

    /// The measured remainder of an opened container, in ``openedQuantityUnitID``.
    ///
    /// Present only where the lot is open and holds exactly one container, since
    /// a measurement describes one container. Always net contents, whatever the
    /// original reading was.
    public var openedAmount: Double?
    public var openedQuantityUnitID: Int?
    /// The container weight subtracted from a gross reading, or `nil` when the
    /// reading was already net.
    public var openedTare: Double?
    /// When ``openedAmount`` was recorded, so a stale figure reads as stale.
    public var openedMeasuredAt: Date?

    public var createdAt: Date?

    public init(
        id: Int,
        stockID: String? = nil,
        productID: Int? = nil,
        locationID: Int? = nil,
        shoppingLocationID: Int? = nil,
        amount: Double = 0,
        bestBeforeDate: Date? = nil,
        purchasedDate: Date? = nil,
        openedDate: Date? = nil,
        price: Double? = nil,
        isOpen: Bool = false,
        note: String? = nil,
        openedAmount: Double? = nil,
        openedQuantityUnitID: Int? = nil,
        openedTare: Double? = nil,
        openedMeasuredAt: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.stockID = stockID
        self.productID = productID
        self.locationID = locationID
        self.shoppingLocationID = shoppingLocationID
        self.amount = amount
        self.bestBeforeDate = bestBeforeDate
        self.purchasedDate = purchasedDate
        self.openedDate = openedDate
        self.price = price
        self.isOpen = isOpen
        self.note = note
        self.openedAmount = openedAmount
        self.openedQuantityUnitID = openedQuantityUnitID
        self.openedTare = openedTare
        self.openedMeasuredAt = openedMeasuredAt
        self.createdAt = createdAt
    }
}

extension StockEntry {
    init?(_ schema: Components.Schemas.StockEntry) {
        self.init(
            id: schema.id,
            stockID: schema.stockId,
            productID: schema.productId,
            locationID: schema.locationId,
            shoppingLocationID: schema.shoppingLocationId,
            amount: schema.amount ?? 0,
            bestBeforeDate: VictualDates.day(schema.bestBeforeDate),
            purchasedDate: VictualDates.day(schema.purchasedDate),
            openedDate: VictualDates.day(schema.openedDate),
            price: schema.price,
            isOpen: .fromWireFlag(schema.open),
            note: schema.note,
            openedAmount: schema.openedAmount,
            openedQuantityUnitID: schema.openedQuId,
            openedTare: schema.openedTare,
            openedMeasuredAt: VictualDates.timestamp(schema.openedMeasuredAt),
            createdAt: VictualDates.timestamp(schema.rowCreatedTimestamp)
        )
    }
}
