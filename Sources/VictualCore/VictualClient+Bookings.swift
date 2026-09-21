import Foundation
import VictualAPI

/// The five stock bookings, and undo.
///
/// Every booking returns a ``StockBooking``: the log rows the server wrote, plus
/// the transaction id they share. One user action commonly touches several stock
/// entries, so undo takes the transaction rather than a row.
///
/// Each of these requires its own permission — `STOCK_CONSUME`,
/// `STOCK_PURCHASE`, `STOCK_OPEN`, `STOCK_INVENTORY`, `STOCK_TRANSFER` — and
/// answers `403` without it. Asking ``capabilities()`` first lets a user
/// interface disable a control and say why, but it does not remove the need to
/// handle that `403`: a key's permissions can change between the two requests.
extension VictualClient {
    /// Removes an amount of a product from stock.
    ///
    /// - Parameters:
    ///   - productID: The product to consume.
    ///   - amount: How much, in the product's stock quantity unit.
    ///   - spoiled: Whether the product was thrown away rather than used. The
    ///     amount leaves stock either way; the distinction is what makes a spoil
    ///     rate meaningful.
    ///   - stockEntryID: A specific lot to consume, by its `stock_id`. Requires
    ///     `amount` to be exactly 1.
    ///   - recipeID: A recipe this was used for, recorded for statistics only.
    ///   - locationID: Consume only from this location. Omitted, stock anywhere
    ///     is considered.
    ///   - allowSubproductSubstitution: For a parent product that is out of
    ///     stock, whether any sub-product in stock may be used instead.
    public func consume(
        productID: Int,
        amount: Double,
        spoiled: Bool = false,
        stockEntryID: String? = nil,
        recipeID: Int? = nil,
        locationID: Int? = nil,
        allowSubproductSubstitution: Bool = false
    ) async throws(VictualError) -> StockBooking {
        try Self.validateSingleEntry(stockEntryID: stockEntryID, amount: amount)
        return try await performBooking {
            try await underlying.postStockProductsByProductIdConsume(
                .init(
                    path: .init(productId: productID),
                    body: .json(
                        .init(
                            amount: amount,
                            transactionType: .consume,
                            spoiled: spoiled,
                            stockEntryId: stockEntryID,
                            recipeId: recipeID,
                            locationId: locationID,
                            allowSubproductSubstitution: allowSubproductSubstitution
                        )
                    )
                )
            )
        } unwrap: { output in
            switch output {
            case .ok(let response): return try response.body.json
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized: throw VictualError.unauthorized
            case .forbidden: throw VictualError.forbidden
            case .undocumented(let statusCode, _): throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Adds an amount of a product to stock.
    ///
    /// - Parameters:
    ///   - bestBeforeDate: The due date of what is being added. Omitted, the
    ///     server uses today, which is rarely what a purchase means — pass one.
    ///   - price: The price per stock quantity unit. Omitted rather than zeroed
    ///     when unknown, so an unpriced purchase does not claim to have been free.
    ///   - locationID: Where it goes. Omitted, the product's default location.
    ///   - shoppingLocationID: Where it was bought. Omitted, no store is recorded.
    ///   - stockLabelType: Whether to print a label, and how many.
    public func purchase(
        productID: Int,
        amount: Double,
        bestBeforeDate: Date? = nil,
        price: Double? = nil,
        locationID: Int? = nil,
        shoppingLocationID: Int? = nil,
        stockLabelType: StockLabelType? = nil,
        note: String? = nil
    ) async throws(VictualError) -> StockBooking {
        try await performBooking {
            try await underlying.postStockProductsByProductIdAdd(
                .init(
                    path: .init(productId: productID),
                    body: .json(
                        .init(
                            amount: amount,
                            bestBeforeDate: bestBeforeDate.map(VictualDates.string(fromDay:)),
                            transactionType: .purchase,
                            price: price,
                            locationId: locationID,
                            shoppingLocationId: shoppingLocationID,
                            stockLabelType: stockLabelType?.rawValue,
                            note: note
                        )
                    )
                )
            )
        } unwrap: { output in
            switch output {
            case .ok(let response): return try response.body.json
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized: throw VictualError.unauthorized
            case .forbidden: throw VictualError.forbidden
            case .undocumented(let statusCode, _): throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Marks an amount of a product as opened.
    ///
    /// - Parameters:
    ///   - stockEntryID: A specific lot to open. Requires `amount` to be 1.
    ///   - measurement: What is left in the container, recorded as it is opened.
    ///     A measurement describes exactly one container, so it requires
    ///     `stockEntryID` and an amount of 1 — both checked here rather than
    ///     spending a request to be told.
    public func open(
        productID: Int,
        amount: Double,
        stockEntryID: String? = nil,
        allowSubproductSubstitution: Bool = false,
        measurement: OpenMeasurement? = nil
    ) async throws(VictualError) -> StockBooking {
        try Self.validateSingleEntry(stockEntryID: stockEntryID, amount: amount)
        if let measurement {
            guard stockEntryID != nil else {
                throw VictualError.badRequest(
                    message: "A measurement describes one container, so it needs a stock entry."
                )
            }
            guard amount == 1 else {
                throw VictualError.badRequest(
                    message: "A measurement describes one container, so the amount must be 1."
                )
            }
            guard !measurement.isGross || measurement.tare != nil else {
                throw VictualError.badRequest(
                    message: "A gross reading needs the container's tare weight to subtract."
                )
            }
        }
        return try await performBooking {
            try await underlying.postStockProductsByProductIdOpen(
                .init(
                    path: .init(productId: productID),
                    body: .json(
                        .init(
                            amount: amount,
                            stockEntryId: stockEntryID,
                            allowSubproductSubstitution: allowSubproductSubstitution,
                            measurement: measurement.map {
                                .init(
                                    amount: $0.amount,
                                    quId: $0.quantityUnitID,
                                    gross: $0.isGross,
                                    tare: $0.tare
                                )
                            }
                        )
                    )
                )
            )
        } unwrap: { output in
            switch output {
            case .ok(let response): return try response.body.json
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized: throw VictualError.unauthorized
            case .forbidden: throw VictualError.forbidden
            case .undocumented(let statusCode, _): throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Corrects a product's stock to a counted amount, adding or removing the
    /// difference.
    ///
    /// The remaining parameters apply only to what an inventory *adds*; a
    /// correction downwards ignores them.
    public func inventory(
        productID: Int,
        newAmount: Double,
        bestBeforeDate: Date? = nil,
        locationID: Int? = nil,
        shoppingLocationID: Int? = nil,
        price: Double? = nil,
        stockLabelType: StockLabelType? = nil,
        note: String? = nil
    ) async throws(VictualError) -> StockBooking {
        try await performBooking {
            try await underlying.postStockProductsByProductIdInventory(
                .init(
                    path: .init(productId: productID),
                    body: .json(
                        .init(
                            newAmount: newAmount,
                            bestBeforeDate: bestBeforeDate.map(VictualDates.string(fromDay:)),
                            shoppingLocationId: shoppingLocationID,
                            locationId: locationID,
                            price: price,
                            stockLabelType: stockLabelType?.rawValue,
                            note: note
                        )
                    )
                )
            )
        } unwrap: { output in
            switch output {
            case .ok(let response): return try response.body.json
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized: throw VictualError.unauthorized
            case .forbidden: throw VictualError.forbidden
            case .undocumented(let statusCode, _): throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Moves an amount of a product from one location to another.
    ///
    /// - Parameter stockEntryID: A specific lot to move. Requires `amount` to be 1.
    public func transfer(
        productID: Int,
        amount: Double,
        fromLocationID: Int,
        toLocationID: Int,
        stockEntryID: String? = nil
    ) async throws(VictualError) -> StockBooking {
        try Self.validateSingleEntry(stockEntryID: stockEntryID, amount: amount)
        guard fromLocationID != toLocationID else {
            throw VictualError.badRequest(
                message: "A transfer needs two different locations."
            )
        }
        return try await performBooking {
            try await underlying.postStockProductsByProductIdTransfer(
                .init(
                    path: .init(productId: productID),
                    body: .json(
                        .init(
                            amount: amount,
                            locationIdFrom: fromLocationID,
                            locationIdTo: toLocationID,
                            stockEntryId: stockEntryID
                        )
                    )
                )
            )
        } unwrap: { output in
            switch output {
            case .ok(let response): return try response.body.json
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized: throw VictualError.unauthorized
            case .forbidden: throw VictualError.forbidden
            case .undocumented(let statusCode, _): throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Reverses a whole booking.
    ///
    /// Takes the transaction id every row of a ``StockBooking`` shares, not a
    /// row id: one user action can write several rows, and undoing only some of
    /// them would leave the household's stock describing something nobody did.
    public func undoTransaction(id: String) async throws(VictualError) {
        try await perform {
            try await underlying.postStockTransactionsByTransactionIdUndo(
                .init(path: .init(transactionId: id))
            )
        } unwrap: { output in
            switch output {
            case .noContent: return
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized: throw VictualError.unauthorized
            case .forbidden: throw VictualError.forbidden
            case .undocumented(let statusCode, _): throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Runs a booking and groups the log rows it wrote under their transaction.
    private func performBooking<Output>(
        _ call: () async throws -> Output,
        unwrap: (Output) throws -> [Components.Schemas.StockLogEntry]
    ) async throws(VictualError) -> StockBooking {
        let rows = try await perform(call, unwrap: unwrap)
        return StockBooking(rows)
    }

    /// Rejects naming a stock entry with any amount but 1.
    ///
    /// The API requires it, and answers `400`. Checking here spends no round
    /// trip to be told something the caller could not have meant.
    private static func validateSingleEntry(
        stockEntryID: String?,
        amount: Double
    ) throws(VictualError) {
        guard stockEntryID != nil else { return }
        guard amount != 1 else { return }
        throw VictualError.badRequest(
            message: "Naming a specific stock entry requires an amount of 1, not \(amount)."
        )
    }
}

/// What is left in a container, recorded as it is opened.
///
/// The stored value is always net contents. A gross reading — the container on
/// the scale — carries its ``tare`` so the server can subtract it.
public struct OpenMeasurement: Hashable, Sendable {
    /// The reading, in ``quantityUnitID``.
    public var amount: Double

    /// The unit the reading was taken in. Must convert to the product's stock
    /// unit; the server refuses when no conversion exists.
    public var quantityUnitID: Int

    /// Whether ``amount`` includes the container's own weight.
    public var isGross: Bool

    /// The container's weight, in the same unit as ``amount``. Required when
    /// ``isGross`` is true, ignored otherwise.
    public var tare: Double?

    /// A net reading: what the container holds, weighed without it.
    public static func net(_ amount: Double, unitID: Int) -> OpenMeasurement {
        OpenMeasurement(amount: amount, quantityUnitID: unitID, isGross: false, tare: nil)
    }

    /// A gross reading: the container and its contents together, with the
    /// container's own weight to subtract.
    public static func gross(
        _ amount: Double,
        unitID: Int,
        tare: Double
    ) -> OpenMeasurement {
        OpenMeasurement(amount: amount, quantityUnitID: unitID, isGross: true, tare: tare)
    }

    public init(amount: Double, quantityUnitID: Int, isGross: Bool = false, tare: Double? = nil) {
        self.amount = amount
        self.quantityUnitID = quantityUnitID
        self.isGross = isGross
        self.tare = tare
    }
}

/// Whether a booking that adds stock should print a label.
public enum StockLabelType: Int, Hashable, Sendable, CaseIterable, Identifiable {
    case none = 1
    case single = 2
    case perUnit = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: "No label"
        case .single: "One label"
        case .perUnit: "A label per unit"
        }
    }
}
