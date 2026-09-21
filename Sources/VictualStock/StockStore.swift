import Foundation
import Observation
import VictualCore

/// What the sidebar is pointing at.
public enum StockScope: Hashable, Sendable, Identifiable {
    /// One of the server's own status buckets.
    case status(StockFilter)
    /// One storage location, by id.
    case location(Int)

    public var id: String {
        switch self {
        case .status(let filter): "status.\(filter.rawValue)"
        case .location(let id): "location.\(id)"
        }
    }
}

/// The stock list: what is on hand, what needs attention, and what the table
/// should currently show.
///
/// One refresh costs four requests — `GET /stock`, `GET /stock/volatile`, and
/// the two entity listings the table cannot render without — and answers all
/// five status buckets between them. `GET /stock/volatile` returning due,
/// overdue, expired and below-minimum together is what makes that possible.
///
/// Searching, sorting and scoping happen over values already fetched. Sending
/// them to the server would be worse than useless here: `GET /stock` accepts no
/// `order`, and naming a price field in one is answered `400` rather than
/// applied.
@MainActor
@Observable
public final class StockStore {
    /// Everything in stock, as `GET /stock` reports it.
    public private(set) var summaries: [StockSummary] = []

    /// The four attention buckets, from one request.
    public private(set) var volatile = VolatileStock()

    /// Quantity units by id. An amount cannot be rendered without one.
    public private(set) var quantityUnits: [Int: QuantityUnit] = [:]

    /// The locations tree, with each location's path already merged in.
    public private(set) var locations: [StorageLocation] = []

    /// The stock entries at ``scope``'s location, when a location is selected.
    public private(set) var locationEntries: [StockEntry] = []

    public private(set) var state: LoadState = .idle

    /// When the last successful refresh finished.
    public private(set) var lastRefreshed: Date?

    /// Which sidebar entry is selected. Changing it to a location fetches that
    /// location's entries; changing it between status buckets costs nothing.
    public var scope: StockScope = .status(.all) {
        didSet {
            guard scope != oldValue else { return }
            locationEntries = []
            if case .location = scope { refreshLocationEntries() }
        }
    }

    /// The text typed into the search field. Matched against product names.
    public var searchText: String = ""

    public var sort: StockSort = .name
    public var sortAscending: Bool = true

    private let client: VictualClient
    private var locationTask: Task<Void, Never>?

    public init(client: VictualClient) {
        self.client = client
    }

    // MARK: - What the table shows

    /// The rows for the current scope, searched and sorted.
    public var rows: [StockRow] {
        unsortedRows
            .filter(matchesSearch)
            .sorted(by: sort, ascending: sortAscending)
    }

    /// How many rows each sidebar entry would show, for its badge.
    public func count(of filter: StockFilter) -> Int {
        switch filter {
        case .all: summaries.count
        case .dueSoon: volatile.due.count
        case .overdue: volatile.overdue.count
        case .expired: volatile.expired.count
        case .belowMinimum: volatile.belowMinimum.count
        }
    }

    /// The product behind a row, for the detail column.
    public func summary(for productID: Int) -> StockSummary? {
        summaries.first { $0.productID == productID }
    }

    /// The unit a product's amounts are counted in.
    public func unit(for product: ProductSummary?) -> QuantityUnit? {
        product?.stockQuantityUnitID.flatMap { quantityUnits[$0] }
    }

    public func location(_ id: Int) -> StorageLocation? {
        locations.first { $0.id == id }
    }

    // MARK: - Fetching

    /// Re-reads everything the list is built from.
    ///
    /// The four requests are independent, so they go out together. A failure in
    /// any of them leaves the previous values in place rather than blanking the
    /// table: stale stock a user can still read beats an empty window.
    public func refresh() async {
        state = .loading
        do {
            async let stockTask = client.currentStock()
            async let volatileTask = client.volatileStock()
            async let unitsTask = client.quantityUnits()
            async let locationsTask = client.locationTree()

            let stock = try await stockTask
            let volatileStock = try await volatileTask
            let units = try await unitsTask
            let tree = try await locationsTask

            summaries = stock
            volatile = volatileStock
            quantityUnits = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
            locations = tree
            lastRefreshed = Date()
            state = .loaded
        } catch {
            state = .failed(VictualError.mapping(error))
        }
        if case .location = scope { refreshLocationEntries() }
    }

    /// Fetches the entries actually sitting in the selected location.
    ///
    /// Deliberately a different request from the rest: `GET /stock` reports a
    /// product's *default* location, which stops matching where the stock is as
    /// soon as anything is transferred.
    private func refreshLocationEntries() {
        guard case .location(let id) = scope else { return }
        locationTask?.cancel()
        locationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await client.stockEntries(locationID: id)
                guard !Task.isCancelled, case .location(id) = self.scope else { return }
                self.locationEntries = entries
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(VictualError.mapping(error))
            }
        }
    }

    /// Awaits the in-flight location fetch, if there is one.
    public func waitForLocationFetch() async {
        await locationTask?.value
    }

    // MARK: - Implementation

    private var unsortedRows: [StockRow] {
        switch scope {
        case .status(.all):
            return summaries.map { StockRow($0, units: quantityUnits) }
        case .status(.dueSoon):
            return volatile.due.map { StockRow($0, units: quantityUnits) }
        case .status(.overdue):
            return volatile.overdue.map { StockRow($0, units: quantityUnits) }
        case .status(.expired):
            return volatile.expired.map { StockRow($0, units: quantityUnits) }
        case .status(.belowMinimum):
            return volatile.belowMinimum.map {
                StockRow(
                    $0,
                    units: quantityUnits,
                    product: summary(for: $0.id)?.product
                )
            }
        case .location:
            return rowsFromLocationEntries()
        }
    }

    /// Folds a location's stock entries into one row per product.
    ///
    /// The value is the server's own formula — price times amount, summed — and
    /// goes `nil` the moment any contributing entry carries no price. Skipping a
    /// priceless entry instead would report a total that silently understates
    /// what is there, which is the same mistake as defaulting a missing price to
    /// zero.
    private func rowsFromLocationEntries() -> [StockRow] {
        var rows: [Int: StockRow] = [:]
        var pricesKnown: [Int: Bool] = [:]

        for entry in locationEntries {
            guard let productID = entry.productID else { continue }
            let product = summary(for: productID)?.product
            var row =
                rows[productID]
                ?? StockRow(
                    productID: productID,
                    name: summary(for: productID)?.displayName ?? "Product \(productID)",
                    value: 0,
                    unit: unit(for: product),
                    product: product
                )

            row.amount += entry.amount
            if entry.isOpen { row.amountOpened += entry.amount }
            if let due = entry.bestBeforeDate {
                row.nextDueDate = min(row.nextDueDate ?? due, due)
            }

            if let price = entry.price {
                row.value = (row.value ?? 0) + price * entry.amount
                pricesKnown[productID] = pricesKnown[productID] ?? true
            } else {
                pricesKnown[productID] = false
            }
            rows[productID] = row
        }

        return rows.map { productID, row in
            var row = row
            if pricesKnown[productID] != true { row.value = nil }
            return row
        }
    }

    private func matchesSearch(_ row: StockRow) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return row.name.localizedCaseInsensitiveContains(needle)
    }
}
