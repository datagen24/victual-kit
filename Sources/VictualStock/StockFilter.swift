/// The status a stock list is narrowed to.
///
/// These are the server's own buckets rather than this package's invention.
/// `GET /stock` answers ``all``; `GET /stock/volatile` answers the other four in
/// a single response, as `due_products`, `overdue_products`, `expired_products`
/// and `missing_products`. Keeping the cases aligned with that response is what
/// lets a sidebar with five entries cost two requests.
public enum StockFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Everything currently in stock.
    case all

    /// Due within the instance's due-soon window.
    ///
    /// The window is a request parameter — `due_soon_days`, defaulting to 5 —
    /// not a property of the product, so two clients can disagree about what
    /// "soon" means without either being wrong.
    case dueSoon

    /// Past its due date but not yet treated as expired.
    case overdue

    /// Past its due date and expired.
    case expired

    /// Below the product's configured minimum stock amount.
    ///
    /// Reported by the server as `missing_products`, which carries only
    /// `id`, `name`, `amount_missing` and `is_partly_in_stock` — not a full
    /// stock row. A view over this case has less to show than the others.
    case belowMinimum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All stock"
        case .dueSoon: "Due soon"
        case .overdue: "Overdue"
        case .expired: "Expired"
        case .belowMinimum: "Below minimum"
        }
    }

    /// Whether this case is served by `GET /stock/volatile` rather than
    /// `GET /stock`.
    public var isVolatile: Bool { self != .all }
}
