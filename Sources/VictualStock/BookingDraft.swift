import Foundation
import VictualCore

/// What a booking form is holding before it is sent.
///
/// Both front ends edit one of these and send ``request``, so a form on the
/// phone and a sheet on the Mac cannot come to disagree about what is valid, or
/// quietly send a different body for the same fields. The views decide which
/// fields to show; this decides what they mean.
public struct BookingDraft: Hashable, Sendable {
    public let action: StockAction
    public let productID: Int

    /// In the product's stock unit. For an inventory, the amount counted.
    public var amount: Double

    /// Consume only: thrown away rather than used, which is what makes a spoil
    /// rate mean anything.
    public var spoiled = false

    /// Purchase and inventory only. Off by default, which omits the date and
    /// lets the server apply the product's own shelf life — including its
    /// after-freezing rule when the destination is a freezer. A form that
    /// pre-filled a date would bypass both.
    public var usesDueDate = false
    public var dueDate: Date

    /// Purchase and inventory only. A price left off is recorded as unknown,
    /// never as zero.
    public var usesPrice = false
    public var price: Double = 0

    /// Where the stock is taken from or put. `nil` means "anywhere" for a
    /// consume and "the product's default" for a purchase. For a transfer, the
    /// source.
    public var locationID: Int?

    /// Transfer only.
    public var destinationID: Int?

    /// A specific lot, by its `stock_id`. The API requires an amount of exactly
    /// 1 alongside one, so choosing a lot sets the amount to 1.
    public var stockEntryID: String? {
        didSet { if stockEntryID != nil { amount = 1 } }
    }

    public var note = ""

    /// Consume and open: take a sub-product's stock when this one has none.
    public var allowSubstitution = false

    /// Starts a draft with the defaults a person most often wants.
    ///
    /// An inventory starts from what the server says is there, so correcting
    /// a count is an edit rather than a re-typing. A transfer starts from where
    /// the stock currently is. Everything else moves one.
    public init(action: StockAction, productID: Int, product: ProductDetail?, now: Date = Date()) {
        self.action = action
        self.productID = productID
        self.amount = action == .inventory ? (product?.stockAmount ?? 0) : 1
        self.locationID = action == .transfer ? product?.location?.id : nil
        self.dueDate = now
    }

    /// Starts a draft for one named lot, as a per-unit label scan does.
    public init(action: StockAction, entry: StockEntry, product: ProductDetail?, now: Date = Date()) {
        self.init(action: action, productID: entry.productID ?? product?.id ?? 0, product: product, now: now)
        self.stockEntryID = entry.stockID
        if action == .transfer { locationID = entry.locationID ?? locationID }
    }

    /// The amounts a stepper should allow.
    ///
    /// An inventory may legitimately be set to zero — "there is none left" is
    /// a count. The other four move an amount, and moving nothing is not a
    /// thing to ask the server to do.
    public var amountRange: ClosedRange<Double> {
        action == .inventory ? 0...100_000 : 0.001...100_000
    }

    /// Whether the fields add up to a booking the server could accept.
    public var isValid: Bool {
        guard productID > 0 else { return false }
        if stockEntryID != nil, amount != 1 { return false }
        switch action {
        case .inventory:
            return amount >= 0
        case .transfer:
            guard let from = locationID, let to = destinationID else { return false }
            return from != to && amount > 0
        case .consume, .purchase, .open:
            return amount > 0
        }
    }

    /// The booking these fields describe.
    public var request: BookingRequest {
        let entry = stockEntryID.flatMap { $0.isEmpty ? nil : $0 }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? nil : trimmedNote
        switch action {
        case .consume:
            return .consume(
                productID: productID,
                amount: amount,
                spoiled: spoiled,
                stockEntryID: entry,
                locationID: locationID,
                allowSubproductSubstitution: allowSubstitution
            )
        case .purchase:
            return .purchase(
                productID: productID,
                amount: amount,
                bestBeforeDate: usesDueDate ? dueDate : nil,
                price: usesPrice ? price : nil,
                locationID: locationID,
                shoppingLocationID: nil,
                stockLabelType: nil,
                note: note
            )
        case .open:
            return .open(
                productID: productID,
                amount: amount,
                stockEntryID: entry,
                allowSubproductSubstitution: allowSubstitution,
                measurement: nil
            )
        case .inventory:
            return .inventory(
                productID: productID,
                newAmount: amount,
                bestBeforeDate: usesDueDate ? dueDate : nil,
                locationID: locationID,
                shoppingLocationID: nil,
                price: usesPrice ? price : nil,
                stockLabelType: nil,
                note: note
            )
        case .transfer:
            return .transfer(
                productID: productID,
                amount: amount,
                fromLocationID: locationID ?? 0,
                toLocationID: destinationID ?? 0,
                stockEntryID: entry
            )
        }
    }
}
