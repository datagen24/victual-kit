import SwiftUI
import VictualCore
import VictualStock

/// The content column: everything the selected sidebar entry covers.
///
/// ## The price column is absent, not empty
///
/// When the key's owner lacks `STOCK_PRICES_VIEW` the column is not rendered at
/// all. A column of em dashes is worse than no column — it occupies space to
/// say nothing. This is the one place in the application where hiding beats
/// disabling; every booking control does the opposite, and says why.
///
/// An em dash *within* the column still means something: the value is genuinely
/// unknown, because a lot in that location carries no recorded price.
struct StockTable: View {
    @Bindable var store: StockStore
    let showsPrices: Bool
    @Binding var selection: Int?

    @State private var sortOrder = [KeyPathComparator(\StockRow.name)]

    var body: some View {
        Group {
            // Two tables rather than one conditional column: `TableColumnBuilder`
            // only gained `buildIf` in macOS 14.4, and this application's floor
            // is macOS 14. The columns themselves are declared once, below.
            if showsPrices {
                Table(store.rows, selection: $selection, sortOrder: $sortOrder) {
                    sharedColumns
                    TableColumn("Value", value: \.sortableValue) { row in
                        ValueCell(value: row.value)
                    }
                    .width(min: 70, ideal: 90)
                }
            } else {
                Table(store.rows, selection: $selection, sortOrder: $sortOrder) {
                    sharedColumns
                }
            }
        }
        .onChange(of: sortOrder) { _, order in
            store.apply(order)
        }
        .overlay {
            if store.rows.isEmpty { emptyState }
        }
    }

    /// The columns every scope shows. The price column is appended above, and
    /// only when the key's owner is permitted to see one.
    @TableColumnBuilder<StockRow, KeyPathComparator<StockRow>>
    private var sharedColumns: some TableColumnContent<StockRow, KeyPathComparator<StockRow>> {
        TableColumn("Product", value: \.name) { row in
            Text(row.name).lineLimit(1)
        }
        .width(min: 160, ideal: 260)

        TableColumn("Amount", value: \.amount) { row in
            AmountCell(row: row)
        }
        .width(min: 90, ideal: 120)

        TableColumn("Due", value: \.sortableDueDate) { row in
            DueCell(date: row.nextDueDate)
        }
        .width(min: 90, ideal: 120)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: "shippingbox")
        } description: {
            Text(emptyMessage)
        }
    }

    private var emptyTitle: String {
        store.state.isLoading ? "Loading" : "Nothing here"
    }

    private var emptyMessage: String {
        if store.state.isLoading { return "Reading stock from the server." }
        if let error = store.state.error {
            return error.errorDescription ?? "The stock list could not be read."
        }
        if !store.searchText.isEmpty { return "No product matches \"\(store.searchText)\"." }
        switch store.scope {
        case .status(.all): return "Nothing is in stock."
        case .status(let filter): return "Nothing is \(filter.title.lowercased())."
        case .location(let id):
            let name = store.location(id)?.displayName ?? "this location"
            return "Nothing is stored in \(name)."
        }
    }
}

/// The amount, with the unit that makes it mean something, and how much of it
/// is already open.
private struct AmountCell: View {
    let row: StockRow

    var body: some View {
        HStack(spacing: 4) {
            Text(row.amountText)
            if row.amountOpened > 0 {
                Image(systemName: "drop")
                    .foregroundStyle(.secondary)
                    .help(
                        "\(QuantityUnit.describe(row.amountOpened, in: row.unit)) already opened"
                    )
            }
            if let missing = row.amountMissing, missing > 0 {
                Text("(\(QuantityUnit.describe(missing, in: row.unit)) short)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .monospacedDigit()
    }
}

/// The next due date, coloured by how close it is.
private struct DueCell: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, format: .dateTime.year().month(.abbreviated).day())
                .foregroundStyle(date < Date() ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .monospacedDigit()
        } else {
            // No due date recorded, which is not the same as "due today".
            Text("—").foregroundStyle(.secondary)
        }
    }
}

/// A value, or an em dash when it is genuinely unknown.
///
/// Reached only when the column is shown at all — so this dash always means
/// "not recorded", never "not permitted".
private struct ValueCell: View {
    let value: Double?

    var body: some View {
        if let value {
            Text(value, format: .number.precision(.fractionLength(2)))
                .monospacedDigit()
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .help("No price is recorded for this stock.")
        }
    }
}

extension StockRow {
    /// A sortable stand-in for the optional due date.
    ///
    /// Only ever used to tell `Table` which column was clicked; the store does
    /// the actual ordering, and puts unknowns last whichever way it points.
    var sortableDueDate: Double {
        nextDueDate?.timeIntervalSinceReferenceDate ?? .greatestFiniteMagnitude
    }

    /// The same stand-in for the optional value.
    var sortableValue: Double { value ?? .greatestFiniteMagnitude }
}

extension StockStore {
    /// Translates a `Table` header click into the store's own sort.
    ///
    /// The comparator itself is discarded: `Table` would sort by the stand-in
    /// key paths, which put an unknown first when reversed. The store's rule —
    /// unknown last, always — is the one that should hold.
    func apply(_ order: [KeyPathComparator<StockRow>]) {
        guard let first = order.first else { return }
        switch first.keyPath {
        case \StockRow.name: sort = .name
        case \StockRow.amount: sort = .amount
        case \StockRow.sortableDueDate: sort = .dueDate
        case \StockRow.sortableValue: sort = .value
        default: return
        }
        sortAscending = first.order == .forward
    }
}
