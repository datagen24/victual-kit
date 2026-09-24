import Foundation
import VictualAPI

/// What one stock booking did.
///
/// A single user action — consuming two of something, or correcting an
/// inventory — can touch several stock entries and so produce several log rows.
/// The server groups them under one `transaction_id`, and undo takes that
/// transaction, never a row. Offering undo per row would let a user unpick half
/// of their own action.
public struct StockBooking: Hashable, Sendable {
    /// The transaction the rows share, and the thing
    /// ``VictualClient/undoTransaction(id:)`` takes.
    ///
    /// `nil` only when the server returned rows without one, in which case the
    /// booking cannot be undone and the UI must not offer to.
    public var transactionID: String?

    /// The log rows the booking wrote, in the order the server returned them.
    public var rows: [StockLogRow]

    /// Whether this booking can be offered for undo.
    public var isUndoable: Bool { transactionID != nil && !rows.isEmpty }

    /// The total amount booked, summed across rows.
    public var totalAmount: Double { rows.reduce(0) { $0 + $1.amount } }

    /// The product the booking was against, when every row agrees on one.
    public var productID: Int? {
        let ids = Set(rows.compactMap(\.productID))
        return ids.count == 1 ? ids.first : nil
    }

    public init(transactionID: String? = nil, rows: [StockLogRow] = []) {
        self.transactionID = transactionID
        self.rows = rows
    }
}

extension StockBooking {
    /// Groups the rows a booking returned under the transaction they share.
    ///
    /// Takes the first row's transaction id: the server writes one transaction
    /// per request, so every row carries the same value.
    init(_ schemas: [Components.Schemas.StockLogEntry]) {
        let rows = schemas.compactMap(StockLogRow.init)
        self.init(transactionID: rows.first?.transactionID, rows: rows)
    }
}

/// One row of the stock log, as a booking returns it.
public struct StockLogRow: Hashable, Sendable, Identifiable {
    public var id: Int
    public var productID: Int?

    /// The amount this row booked. Negative for a consumption.
    public var amount: Double

    /// The transaction this row belongs to. Every row of one booking shares it.
    public var transactionID: String?
    public var transactionType: StockTransactionKind?

    /// Whether the product was recorded as spoiled rather than used.
    public var spoiled: Bool

    /// The stock entry this row moved.
    public var stockID: String?

    /// What the row was priced at.
    ///
    /// Two different absences meet here, and the API distinguishes them: a
    /// booking that carries no price — a consumption — sends an explicit null,
    /// while a caller without `STOCK_PRICES_VIEW` does not get the field at all.
    /// Both arrive as `nil`, and neither is zero.
    public var price: Double?

    public var note: String?
    public var bestBeforeDate: Date?
    public var purchasedDate: Date?
    public var usedDate: Date?
    public var createdAt: Date?

    public init(
        id: Int,
        productID: Int? = nil,
        amount: Double = 0,
        transactionID: String? = nil,
        transactionType: StockTransactionKind? = nil,
        spoiled: Bool = false,
        stockID: String? = nil,
        price: Double? = nil,
        note: String? = nil,
        bestBeforeDate: Date? = nil,
        purchasedDate: Date? = nil,
        usedDate: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.productID = productID
        self.amount = amount
        self.transactionID = transactionID
        self.transactionType = transactionType
        self.spoiled = spoiled
        self.stockID = stockID
        self.price = price
        self.note = note
        self.bestBeforeDate = bestBeforeDate
        self.purchasedDate = purchasedDate
        self.usedDate = usedDate
        self.createdAt = createdAt
    }
}

extension StockLogRow {
    init?(_ schema: Components.Schemas.StockLogEntry) {
        guard let id = schema.id else { return nil }
        self.init(
            id: id,
            productID: schema.productId,
            amount: schema.amount ?? 0,
            transactionID: schema.transactionId,
            transactionType: schema.transactionType.map(StockTransactionKind.init),
            // `integer` 0/1 on the wire, like every other flag this API sends;
            // the document said `boolean` and `Scripts/update-openapi.py` repairs it.
            spoiled: .fromWireFlag(schema.spoiled),
            stockID: schema.stockId,
            price: schema.price,
            note: schema.note,
            bestBeforeDate: VictualDates.day(schema.bestBeforeDate),
            purchasedDate: VictualDates.day(schema.purchasedDate),
            usedDate: VictualDates.day(schema.usedDate),
            createdAt: VictualDates.timestamp(schema.rowCreatedTimestamp)
        )
    }
}

/// What kind of booking wrote a stock log row.
///
/// The wire spellings are the API's own; `transfer` and `open` are not among
/// them, because the server records a transfer as a consumption plus a purchase
/// and an opening as ``productOpened``.
public enum StockTransactionKind: String, Hashable, Sendable, CaseIterable, Codable {
    case purchase = "purchase"
    case consume = "consume"
    case inventoryCorrection = "inventory-correction"
    case productOpened = "product-opened"

    public var title: String {
        switch self {
        case .purchase: "Purchase"
        case .consume: "Consume"
        case .inventoryCorrection: "Inventory correction"
        case .productOpened: "Opened"
        }
    }
}

extension StockTransactionKind {
    init(_ schema: Components.Schemas.StockTransactionType) {
        switch schema {
        case .purchase: self = .purchase
        case .consume: self = .consume
        case .inventoryCorrection: self = .inventoryCorrection
        case .productOpened: self = .productOpened
        }
    }

    var schema: Components.Schemas.StockTransactionType {
        switch self {
        case .purchase: .purchase
        case .consume: .consume
        case .inventoryCorrection: .inventoryCorrection
        case .productOpened: .productOpened
        }
    }
}
