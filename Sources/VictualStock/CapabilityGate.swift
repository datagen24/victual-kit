import Foundation
import Observation
import VictualCore

/// What the signed-in key may do, in the terms a user interface asks in.
///
/// ## These are a courtesy, not a guarantee
///
/// A key's permissions can change between this fetch and the next booking, so
/// every write still handles `403`. What the gate buys is a control that is
/// disabled *and says why* — which is a better answer than an error after the
/// fact, and why the plan calls for disabling rather than hiding: a household
/// member should be able to see that consume exists and that they lack
/// `STOCK_CONSUME`. A control that vanishes teaches nothing.
///
/// Before ``load()`` has answered, every gate reads `true`. Guessing
/// permissively means a control may be offered and then refused — which the
/// backstop already handles — whereas guessing restrictively would show every
/// control greyed out for the moment after launch, and wrongly.
@MainActor
@Observable
public final class CapabilityGate {
    /// What the server reported, once it has.
    public private(set) var capabilities: VictualCapabilities?

    public private(set) var state: LoadState = .idle

    private let client: VictualClient

    public init(client: VictualClient, capabilities: VictualCapabilities? = nil) {
        self.client = client
        self.capabilities = capabilities
        self.state = capabilities == nil ? .idle : .loaded
    }

    /// Fetches `GET /user/capabilities`.
    ///
    /// A failure leaves the gates permissive and records the error: not knowing
    /// what a key may do is not a reason to lock a user out of their own
    /// household's stock.
    public func load() async {
        state = .loading
        do {
            capabilities = try await client.capabilities()
            state = .loaded
        } catch {
            state = .failed(error)
        }
    }

    public var canConsume: Bool { canWrite(.consume) }
    public var canPurchase: Bool { canWrite(.purchase) }
    public var canOpen: Bool { canWrite(.open) }
    public var canInventory: Bool { canWrite(.inventory) }
    public var canTransfer: Bool { canWrite(.transfer) }

    /// Whether the key can undo a booking it made.
    ///
    /// The server answers an undo with `403` unless the key holds `STOCK_EDIT`
    /// (`POST /stock/transactions/{id}/undo`). A key that may consume but not
    /// edit would otherwise be offered an undo for a booking that already went
    /// through, and refused when it used it.
    public var canUndo: Bool { canWrite(permission: VictualPermission.stockEdit) }

    /// Why undo is unavailable, or `nil` when it is available.
    public var undoReason: String? {
        capabilities?.obstacle(to: VictualPermission.stockEdit)
    }

    /// Whether prices should be shown at all.
    ///
    /// When this is false the price column is **absent**, not empty: a column of
    /// em dashes is worse than no column. It is the one place where hiding beats
    /// disabling.
    public var canSeePrices: Bool {
        guard let capabilities else { return true }
        return capabilities.allows(VictualPermission.stockPricesView)
    }

    /// Whether the key refuses every write regardless of permissions.
    public var isReadOnlyKey: Bool { capabilities?.isReadOnly ?? false }

    /// Whether `action` is worth offering.
    public func canWrite(_ action: StockAction) -> Bool {
        canWrite(permission: action.permission)
    }

    private func canWrite(permission: String) -> Bool {
        guard let capabilities else { return true }
        return capabilities.canWrite(permission)
    }

    /// What `action` is missing, in a few words for a menu row where there is
    /// no room for a sentence, or `nil` when it is available.
    public func shortReason(_ action: StockAction) -> String? {
        guard let capabilities, !capabilities.canWrite(action.permission) else { return nil }
        return capabilities.isReadOnly ? "read-only key" : "needs \(action.permission)"
    }

    /// Why `action` is unavailable, phrased for a tooltip, or `nil` when it is
    /// available.
    public func reason(_ action: StockAction) -> String? {
        capabilities?.obstacle(to: action.permission)
    }
}
