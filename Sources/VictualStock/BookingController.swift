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

    /// Whether the last booking failed in a way ``retryLast()`` can safely
    /// send again.
    ///
    /// True only when its outcome is unknown or the server was still working on
    /// it, its key went to a server that honours keys for that booking, and the
    /// server's retention has not run out since the first attempt. Anything else
    /// — above all a server before 0.5.0 — could book a second time, so the
    /// answer is in the refreshed stock instead.
    public private(set) var canRetryLast = false

    private let client: VictualClient
    private let gate: CapabilityGate?

    /// The booking last sent and not yet known to have succeeded, with the key
    /// it went out under.
    ///
    /// Sending the same request again reuses the key, which is what lets the
    /// server answer a retry with the original booking instead of a second one.
    private var pending: PendingBooking?

    /// The clock retention is measured against. A seam for tests.
    var now: @MainActor () -> Date = { Date() }

    /// - Parameter gate: What the key may do. Given one, a booking is not
    ///   offered for undo when the key could not carry the undo out.
    public init(client: VictualClient, gate: CapabilityGate? = nil) {
        self.client = client
        self.gate = gate
    }

    /// Whether the last booking is worth confirming to the user, undoable or not.
    ///
    /// False for a booking the server returned without a transaction id. A key
    /// that cannot undo still wants to hear that its booking went through.
    public var hasConfirmableBooking: Bool {
        lastBooking?.isUndoable == true && !isWorking
    }

    /// Whether there is something to offer undo for.
    ///
    /// False for a booking the server returned without a transaction id, where
    /// there would be nothing to address the undo to, and for a key without the
    /// permission undo needs. Offering a button that cannot work is worse than
    /// offering none.
    public var canUndoLast: Bool {
        hasConfirmableBooking && (gate?.canUndo ?? true)
    }

    /// Performs a booking.
    ///
    /// - Returns: Whether it succeeded. A `403` here is expected and handled:
    ///   ``CapabilityGate`` can only report what was true when it last asked.
    ///
    /// The same request performed again — after a failure, before any other —
    /// goes out under the same ``StockBookingKey``, so a server that honours keys
    /// answers it with the first booking if that one did land.
    @discardableResult
    public func perform(_ request: BookingRequest) async -> Bool {
        let key = key(for: request, retention: client.knownStockBookingIdempotency?.retention)
        return await send(request, key: key)
    }

    /// Sends the last booking again, under the key it first went out with.
    ///
    /// - Returns: Whether it succeeded. Does nothing, and returns `false`, unless
    ///   ``canRetryLast`` is true — and re-checks retention first, because a
    ///   key the server has forgotten would book a second time.
    @discardableResult
    public func retryLast() async -> Bool {
        guard canRetryLast, let pending else { return false }
        guard let protection = client.knownStockBookingIdempotency,
            isProtected(pending, by: protection)
        else {
            canRetryLast = false
            return false
        }
        return await send(pending.request, key: pending.key)
    }

    private func send(_ request: BookingRequest, key: StockBookingKey) async -> Bool {
        isWorking = true
        error = nil
        canRetryLast = false
        defer { isWorking = false }
        do {
            let booking = try await book(request, key: key)
            pending = nil
            lastBooking = booking
            lastAction = request.action
            return true
        } catch {
            let failure = VictualError.writeFailure(error)
            self.error = failure
            lastBooking = nil
            lastAction = nil
            switch failure {
            case .idempotencyConflict:
                // The key is spent on something else. Retrying it can only be
                // refused again, and a new key could book twice.
                pending = nil
            case .outcomeUnknown, .idempotencyInProgress:
                // The booking itself taught the client the capability, if it
                // could be learned; without it, the key was not sent.
                if let pending, let protection = client.knownStockBookingIdempotency {
                    canRetryLast = isProtected(pending, by: protection)
                }
            default:
                break
            }
            await refreshPermissionsIfForbidden()
            return false
        }
    }

    /// The key to send `request` under: the pending one when this is the same
    /// booking again and the server would still recognise it, a new one
    /// otherwise.
    private func key(for request: BookingRequest, retention: TimeInterval?) -> StockBookingKey {
        if let pending, pending.request == request,
            retention.map({ now().timeIntervalSince(pending.firstSent) < $0 }) ?? true
        {
            return pending.key
        }
        let fresh = PendingBooking(request: request, key: StockBookingKey(), firstSent: now())
        pending = fresh
        return fresh.key
    }

    /// Whether the server honours keys for `pending`'s booking and still
    /// remembers its key. Counted from the first attempt, never the last.
    private func isProtected(
        _ pending: PendingBooking,
        by protection: StockBookingIdempotency
    ) -> Bool {
        protection.protects(pending.request.operation)
            && now().timeIntervalSince(pending.firstSent) < protection.retention
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
            self.error = VictualError.writeFailure(error)
            await refreshPermissionsIfForbidden()
            return false
        }
    }

    /// Asks the gate to read the key's permissions again after a `403`.
    ///
    /// The gate reads them once, so a permission changed on the server since
    /// then would otherwise go on offering a control the server refuses.
    private func refreshPermissionsIfForbidden() async {
        guard error == .forbidden else { return }
        await gate?.load()
    }

    /// Withdraws the undo affordance without undoing anything.
    public func dismissUndo() {
        lastBooking = nil
        lastAction = nil
    }

    public func clearError() {
        error = nil
        canRetryLast = false
    }

    private func book(_ request: BookingRequest, key: StockBookingKey) async throws -> StockBooking {
        switch request {
        case .consume(let productID, let amount, let spoiled, let entry, let location, let subs):
            return try await client.consume(
                productID: productID,
                amount: amount,
                spoiled: spoiled,
                stockEntryID: entry,
                locationID: location,
                allowSubproductSubstitution: subs,
                idempotencyKey: key
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
                note: note,
                idempotencyKey: key
            )
        case .open(let productID, let amount, let entry, let subs, let measurement):
            return try await client.open(
                productID: productID,
                amount: amount,
                stockEntryID: entry,
                allowSubproductSubstitution: subs,
                measurement: measurement,
                idempotencyKey: key
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
                note: note,
                idempotencyKey: key
            )
        case .transfer(let productID, let amount, let from, let to, let entry):
            return try await client.transfer(
                productID: productID,
                amount: amount,
                fromLocationID: from,
                toLocationID: to,
                stockEntryID: entry,
                idempotencyKey: key
            )
        }
    }
}

/// A booking sent and not yet known to have succeeded.
private struct PendingBooking {
    let request: BookingRequest
    let key: StockBookingKey
    /// When the key first went out. Retention counts from here.
    let firstSent: Date
}

extension BookingRequest {
    /// The booking as the server names it when it says which bookings honour a
    /// key.
    var operation: StockBookingOperation {
        switch action {
        case .consume: .consume
        case .purchase: .purchase
        case .open: .open
        case .inventory: .inventory
        case .transfer: .transfer
        }
    }
}
