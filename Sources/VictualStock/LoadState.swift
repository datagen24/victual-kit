import VictualCore

/// Where a store is in its fetch cycle.
///
/// ``loading`` is deliberately distinct from ``idle``: a view shows a spinner
/// for the first but not the second, and "we have not asked yet" is not the
/// same claim as "we asked and there is nothing".
public enum LoadState: Sendable, Equatable {
    /// Nothing has been fetched yet.
    case idle
    /// A fetch is in flight.
    case loading
    /// The last fetch succeeded.
    case loaded
    /// The last fetch failed. The store keeps whatever it had before.
    case failed(VictualError)

    public var isLoading: Bool { self == .loading }

    public var error: VictualError? {
        if case .failed(let error) = self { return error }
        return nil
    }

    /// Whether a view has something to show, even if the latest fetch failed.
    public var hasLoadedOnce: Bool {
        switch self {
        case .loaded: true
        case .idle, .loading, .failed: false
        }
    }
}

/// The five bookings, as a thing a menu item or a sheet can be about.
///
/// Carrying the permission alongside the name is what lets a disabled control
/// say *which* permission it is missing rather than just that it is unavailable.
public enum StockAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case consume
    case purchase
    case open
    case inventory
    case transfer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .consume: "Consume"
        case .purchase: "Add to stock"
        case .open: "Mark opened"
        case .inventory: "Correct inventory"
        case .transfer: "Transfer"
        }
    }

    /// The permission the server requires for this booking.
    public var permission: String {
        switch self {
        case .consume: VictualPermission.stockConsume
        case .purchase: VictualPermission.stockPurchase
        case .open: VictualPermission.stockOpen
        case .inventory: VictualPermission.stockInventory
        case .transfer: VictualPermission.stockTransfer
        }
    }
}
