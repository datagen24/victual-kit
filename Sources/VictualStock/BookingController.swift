import Foundation
import Observation
import VictualCore

/// One of the five bookings, with everything it needs to be performed.
///
/// A request rather than five methods, so a sheet can build one, a test can
/// compare one, and the controller has a single path through which every
/// booking's result, error and undo affordance are handled the same way.
public enum BookingRequest: Hashable, Sendable {
    case consume(
        productID: Int,
        amount: Double,
        spoiled: Bool = false,
        stockEntryID: String? = nil,
        locationID: Int? = nil,
        allowSubproductSubstitution: Bool = false
    )
    case purchase(
        productID: Int,
        amount: Double,
        bestBeforeDate: Date? = nil,
        price: Double? = nil,
        locationID: Int? = nil,
        shoppingLocationID: Int? = nil,
        stockLabelType: StockLabelType? = nil,
        note: String? = nil
    )
    case open(
        productID: Int,
        amount: Double,
        stockEntryID: String? = nil,
        allowSubproductSubstitution: Bool = false,
        measurement: OpenMeasurement? = nil
    )
    case inventory(
        productID: Int,
        newAmount: Double,
        bestBeforeDate: Date? = nil,
        locationID: Int? = nil,
        shoppingLocationID: Int? = nil,
        price: Double? = nil,
        stockLabelType: StockLabelType? = nil,
        note: String? = nil
    )
    case transfer(
        productID: Int,
        amount: Double,
        fromLocationID: Int,
        toLocationID: Int,
        stockEntryID: String? = nil
    )

    /// Which booking this is, for permissions and for naming it to the user.
    public var action: StockAction {
        switch self {
        case .consume: .consume
        case .purchase: .purchase
        case .open: .open
        case .inventory: .inventory
        case .transfer: .transfer
        }
    }

    public var productID: Int {
        switch self {
        case .consume(let id, _, _, _, _, _): id
        case .purchase(let id, _, _, _, _, _, _, _): id
        case .open(let id, _, _, _, _): id
        case .inventory(let id, _, _, _, _, _, _, _): id
        case .transfer(let id, _, _, _, _): id
        }
    }
}

/// Performs bookings, and holds the last one so it can be undone.
///
/// Undo is offered per *transaction*, never per row: one user action commonly
/// writes several log rows, and letting a user unpick half of their own action
/// would leave the household's stock describing something nobody did.
@MainActor
@Observable
public final class BookingController {
    /// Whether a booking or an undo is in flight.
    public private(set) var isWorking = false

    /// The last booking that succeeded, while its undo is still on offer.
    public private(set) var lastBooking: StockBooking?

    /// What that booking was, for the undo affordance's wording.
    public private(set) var lastAction: StockAction?

    /// The last failure, for an alert. Cleared when the next booking starts.
    public private(set) var error: VictualError?

    private let client: VictualClient

    public init(client: VictualClient) {
        self.client = client
    }

    /// Whether there is something to offer undo for.
    ///
    /// False for a booking the server returned without a transaction id: there
    /// would be nothing to address the undo to, and offering a button that
    /// cannot work is worse than offering none.
    public var canUndoLast: Bool {
        lastBooking?.isUndoable == true && !isWorking
    }

    /// Performs a booking.
    ///
    /// - Returns: Whether it succeeded. A `403` here is expected and handled:
    ///   ``CapabilityGate`` can only report what was true when it last asked.
    @discardableResult
    public func perform(_ request: BookingRequest) async -> Bool {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let booking = try await send(request)
            lastBooking = booking
            lastAction = request.action
            return true
        } catch {
            self.error = VictualError.mapping(error)
            lastBooking = nil
            lastAction = nil
            return false
        }
    }

    /// Reverses the last booking.
    ///
    /// - Returns: Whether the undo succeeded. The affordance is withdrawn either
    ///   way: a failed undo needs the user to see the error, not to try the same
    ///   button again.
    @discardableResult
    public func undoLast() async -> Bool {
        guard let transactionID = lastBooking?.transactionID else { return false }
        isWorking = true
        error = nil
        defer {
            isWorking = false
            lastBooking = nil
            lastAction = nil
        }
        do {
            try await client.undoTransaction(id: transactionID)
            return true
        } catch {
            self.error = VictualError.mapping(error)
            return false
        }
    }

    /// Withdraws the undo affordance without undoing anything.
    public func dismissUndo() {
        lastBooking = nil
        lastAction = nil
    }

    public func clearError() {
        error = nil
    }

    private func send(_ request: BookingRequest) async throws -> StockBooking {
        switch request {
        case .consume(let productID, let amount, let spoiled, let entry, let location, let subs):
            return try await client.consume(
                productID: productID,
                amount: amount,
                spoiled: spoiled,
                stockEntryID: entry,
                locationID: location,
                allowSubproductSubstitution: subs
            )
        case .purchase(
            let productID, let amount, let due, let price, let location, let shop, let label,
            let note):
            return try await client.purchase(
                productID: productID,
                amount: amount,
                bestBeforeDate: due,
                price: price,
                locationID: location,
                shoppingLocationID: shop,
                stockLabelType: label,
                note: note
            )
        case .open(let productID, let amount, let entry, let subs, let measurement):
            return try await client.open(
                productID: productID,
                amount: amount,
                stockEntryID: entry,
                allowSubproductSubstitution: subs,
                measurement: measurement
            )
        case .inventory(
            let productID, let newAmount, let due, let location, let shop, let price, let label,
            let note):
            return try await client.inventory(
                productID: productID,
                newAmount: newAmount,
                bestBeforeDate: due,
                locationID: location,
                shoppingLocationID: shop,
                price: price,
                stockLabelType: label,
                note: note
            )
        case .transfer(let productID, let amount, let from, let to, let entry):
            return try await client.transfer(
                productID: productID,
                amount: amount,
                fromLocationID: from,
                toLocationID: to,
                stockEntryID: entry
            )
        }
    }
}
