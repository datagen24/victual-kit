import Foundation
import VictualCore

/// One line of the stock table, whichever sidebar entry produced it.
///
/// A status bucket and a location produce their rows from different endpoints —
/// `GET /stock` and `GET /stock/locations/{id}/entries` — and the table should
/// not care which. This is the shape they agree on.
public struct StockRow: Identifiable, Hashable, Sendable {
    public var productID: Int
    public var id: Int { productID }

    public var name: String

    /// The amount on hand, in ``unit``.
    public var amount: Double

    /// How much of ``amount`` is in opened containers.
    public var amountOpened: Double

    /// The value of the stock this row covers, or `nil` when it is unknown.
    ///
    /// Two different absences arrive here and neither is a zero: the key's owner
    /// may not see prices at all, or a contributing stock entry carries no
    /// recorded price. Render an em dash, or — when the whole column is
    /// redacted — leave the column out.
    public var value: Double?

    public var nextDueDate: Date?

    /// The unit ``amount`` is counted in, once quantity units have been fetched.
    public var unit: QuantityUnit?

    /// The product, when the row came from a source that carries it.
    public var product: ProductSummary?

    /// How far below its minimum this product is, for the below-minimum bucket.
    public var amountMissing: Double?

    /// `"2.5 packs"`, or the bare number when no unit is known.
    public var amountText: String { QuantityUnit.describe(amount, in: unit) }

    public init(
        productID: Int,
        name: String,
        amount: Double = 0,
        amountOpened: Double = 0,
        value: Double? = nil,
        nextDueDate: Date? = nil,
        unit: QuantityUnit? = nil,
        product: ProductSummary? = nil,
        amountMissing: Double? = nil
    ) {
        self.productID = productID
        self.name = name
        self.amount = amount
        self.amountOpened = amountOpened
        self.value = value
        self.nextDueDate = nextDueDate
        self.unit = unit
        self.product = product
        self.amountMissing = amountMissing
    }
}

extension StockRow {
    /// A row from a `GET /stock` summary.
    ///
    /// A parent product reports its own stock in `amount` and its own plus its
    /// sub-products' in `amount_aggregated`; the aggregate is what a household
    /// means by "how much pasta is there", so it is shown when the server fills it.
    ///
    /// ``value`` crosses over untouched. `GET /stock` sums a missing price as 0
    /// (`stock_current.value` is `SUM(IFNULL(price, 0) * amount)`), so a total of
    /// 0 may mean "free" or "no price recorded", and this response cannot say
    /// which. Only a stock entry's own `price` can, which is why a location view
    /// shows a dash for an unpriced entry and this list shows 0.
    init(_ summary: StockSummary, units: [Int: QuantityUnit]) {
        let aggregated = summary.isAggregatedAmount
        self.init(
            productID: summary.productID,
            name: summary.displayName,
            amount: (aggregated ? summary.amountAggregated : nil) ?? summary.amount,
            amountOpened: (aggregated ? summary.amountOpenedAggregated : nil)
                ?? summary.amountOpened,
            value: summary.value,
            nextDueDate: summary.nextDueDate,
            unit: summary.product?.stockQuantityUnitID.flatMap { units[$0] },
            product: summary.product
        )
    }

    /// A row from the below-minimum bucket.
    ///
    /// The bucket says how much is missing, not how much is there, so the amount
    /// comes from the product's stock row when it has one. A product with no
    /// stock row has none on hand, and takes its unit from the product the
    /// bucket embeds.
    init(_ missing: MissingProduct, units: [Int: QuantityUnit], stock: StockSummary?) {
        let product = missing.product ?? stock?.product
        let row = stock.map { StockRow($0, units: units) }
        self.init(
            productID: missing.id,
            name: missing.name,
            amount: row?.amount ?? 0,
            amountOpened: row?.amountOpened ?? 0,
            value: row?.value,
            nextDueDate: row?.nextDueDate,
            unit: product?.stockQuantityUnitID.flatMap { units[$0] },
            product: product,
            amountMissing: missing.amountMissing
        )
    }
}

/// How the stock table is ordered.
///
/// Sorting happens here rather than through the API's `order` parameter,
/// deliberately: naming a price field in `order` is answered `400` rather than
/// applied, and `GET /stock` does not accept the parameter at all.
public enum StockSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case name
    case amount
    case dueDate
    case value

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: "Name"
        case .amount: "Amount"
        case .dueDate: "Due"
        case .value: "Value"
        }
    }
}

extension Array where Element == StockRow {
    /// Orders rows, keeping unknown values last whichever direction is asked
    /// for.
    ///
    /// A row with no due date is not "earliest", and a row whose value is
    /// redacted is not "cheapest". Sinking them to the bottom either way says
    /// "unknown" rather than asserting a position.
    func sorted(by sort: StockSort, ascending: Bool) -> [StockRow] {
        func order<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
            switch (a, b) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?):
                if a == b { return nil }
                return ascending ? a < b : a > b
            }
        }

        return sorted { first, second in
            let decided: Bool?
            switch sort {
            case .name:
                decided =
                    first.name == second.name
                    ? nil
                    : (ascending
                        ? first.name.localizedStandardCompare(second.name) == .orderedAscending
                        : first.name.localizedStandardCompare(second.name) == .orderedDescending)
            case .amount:
                decided = order(first.amount, second.amount)
            case .dueDate:
                decided = order(first.nextDueDate, second.nextDueDate)
            case .value:
                decided = order(first.value, second.value)
            }
            // Ties break on name so the order is stable between refreshes.
            return decided
                ?? (first.name.localizedStandardCompare(second.name) == .orderedAscending)
        }
    }
}
