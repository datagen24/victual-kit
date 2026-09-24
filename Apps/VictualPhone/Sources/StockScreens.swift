import SwiftUI
import VictualCore
import VictualStock

/// The stock list, filtered by the server's own status buckets.
struct StockScreen: View {
    let workspace: PhoneWorkspace

    @State private var filter: StockFilter = .all

    private var stock: StockStore { workspace.stock }

    var body: some View {
        @Bindable var stock = workspace.stock

        NavigationStack {
            List(stock.rows) { row in
                NavigationLink(value: ScanDestination.product(row.productID)) {
                    StockRowView(row: row)
                }
            }
            .listStyle(.plain)
            .overlay { if stock.rows.isEmpty { emptyState } }
            .navigationTitle(filter.title)
            .searchable(text: $stock.searchText, prompt: "Search stock")
            .refreshable { await stock.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .safeAreaInset(edge: .bottom) {
                UndoBar(bookings: workspace.bookings) { await workspace.undoLastBooking() }
            }
            .navigationDestination(for: ScanDestination.self) { destination in
                switch destination {
                case .product(let id): ProductScreen(workspace: workspace, productID: id)
                case .location(let target): LocationScreen(workspace: workspace, location: target)
                }
            }
            .onChange(of: filter) { _, new in stock.scope = .status(new) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(StockFilter.allCases) { filter in
                    Text("\(filter.title) (\(stock.count(of: filter)))").tag(filter)
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if stock.state.isLoading {
            ProgressView()
        } else if let error = stock.state.error {
            ContentUnavailableView(
                "Could not read stock",
                systemImage: "exclamationmark.triangle",
                description: Text(error.errorDescription ?? "")
            )
        } else if !stock.searchText.isEmpty {
            ContentUnavailableView.search(text: stock.searchText)
        } else {
            ContentUnavailableView(
                filter == .all ? "Nothing in stock" : "Nothing is \(filter.title.lowercased())",
                systemImage: "shippingbox"
            )
        }
    }
}

private struct StockRowView: View {
    let row: StockRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                if let missing = row.amountMissing, missing > 0 {
                    Text("\(QuantityUnit.describe(missing, in: row.unit)) short")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.amountText).monospacedDigit()
                if let due = row.nextDueDate {
                    Text(due, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(due < Calendar.current.startOfDay(for: .now) ? .red : .secondary)
                }
            }
        }
    }
}

/// One product, and the lots it is made of.
struct ProductScreen: View {
    let workspace: PhoneWorkspace
    let productID: Int

    @State private var store: ProductDetailStore

    init(workspace: PhoneWorkspace, productID: Int) {
        self.workspace = workspace
        self.productID = productID
        self._store = State(initialValue: ProductDetailStore(client: workspace.client))
    }

    var body: some View {
        List {
            if let detail = store.detail {
                Section {
                    ProductPanel(workspace: workspace, detail: detail, entry: nil, linksToDetail: false)
                        .padding(.vertical, 4)
                }
                Section("Stock entries") {
                    if store.orderedEntries.isEmpty {
                        Text("Nothing in stock.").foregroundStyle(.secondary)
                    }
                    ForEach(store.orderedEntries) { entry in
                        EntryRow(entry: entry, unit: detail.stockQuantityUnit, locationName: locationName(entry))
                            .swipeActions(edge: .trailing) {
                                if entry.stockID != nil, workspace.capabilities.canConsume {
                                    Button("Use") {
                                        Task { await consume(entry, of: detail) }
                                    }
                                    .tint(.accentColor)
                                }
                            }
                            .contextMenu {
                                if entry.stockID != nil {
                                    ForEach(StockAction.allCases.filter { $0 != .purchase }) { action in
                                        Button(action.title) {
                                            workspace.beginBooking(action, product: detail, entry: entry)
                                        }
                                        .disabled(!workspace.capabilities.canWrite(action))
                                    }
                                }
                            }
                    }
                }
            } else if store.state.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = store.state.error {
                ContentUnavailableView(
                    "Could not read this product",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.errorDescription ?? "")
                )
            }
        }
        .navigationTitle(store.detail?.product.name ?? "Product")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            store.refresh()
            await store.waitForLoad()
        }
        .onAppear { store.select(productID) }
        // A booking made anywhere — this screen, the scan card, the web —
        // moves the stock list; re-read this product when it does.
        .onChange(of: workspace.stock.lastRefreshed) { _, _ in store.refresh() }
        .safeAreaInset(edge: .bottom) {
            UndoBar(bookings: workspace.bookings) { await workspace.undoLastBooking() }
        }
    }

    private func locationName(_ entry: StockEntry) -> String? {
        entry.locationID.flatMap(workspace.stock.location).map { $0.path ?? $0.displayName }
    }

    private func consume(_ entry: StockEntry, of detail: ProductDetail) async {
        await workspace.bookOne(.consume, of: detail, entry: entry)
    }
}

/// What is actually in one location, as a location label scan asks.
///
/// Read from `GET /stock/locations/{id}/entries`, which reports where stock
/// *is*, rather than filtering the stock list by each product's default
/// location — the mistake the macOS plan records avoiding.
struct LocationScreen: View {
    let workspace: PhoneWorkspace
    let location: LabelTarget

    @State private var entries: [StockEntry] = []
    @State private var state: LoadState = .idle

    var body: some View {
        List {
            if location.path != location.name {
                Section { Text(location.path).foregroundStyle(.secondary) }
            }
            Section("In here") {
                if state.isLoading && entries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error = state.error {
                    Text(error.errorDescription ?? "Could not read this location.")
                        .foregroundStyle(.secondary)
                } else if entries.isEmpty {
                    Text("Nothing is stored here.").foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.productID) { group in
                    NavigationLink(value: ScanDestination.product(group.productID)) {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text(QuantityUnit.describe(group.amount, in: group.unit))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workspace.stock.lastRefreshed) { await load() }
        .refreshable { await load() }
    }

    private struct Group {
        let productID: Int
        let name: String
        let amount: Double
        let unit: QuantityUnit?
    }

    private var grouped: [Group] {
        let byProduct = Dictionary(grouping: entries.filter { $0.productID != nil }) { $0.productID! }
        return byProduct.map { productID, lots in
            let summary = workspace.stock.summary(for: productID)
            return Group(
                productID: productID,
                name: summary?.product?.name ?? "Product \(productID)",
                amount: lots.reduce(0) { $0 + $1.amount },
                unit: workspace.stock.unit(for: summary?.product)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func load() async {
        state = .loading
        do {
            entries = try await workspace.client.stockEntries(locationID: location.id)
            state = .loaded
        } catch {
            state = .failed(error)
        }
    }
}

/// One lot, with what tells it apart from the others.
private struct EntryRow: View {
    let entry: StockEntry
    let unit: QuantityUnit?
    let locationName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(QuantityUnit.describe(entry.amount, in: unit)).monospacedDigit()
                if entry.isOpen {
                    Text("opened")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: .capsule)
                }
            }
            HStack(spacing: 10) {
                if let due = entry.bestBeforeDate {
                    Label(due.formatted(.dateTime.year().month(.abbreviated).day()), systemImage: "calendar")
                        .foregroundStyle(due < Calendar.current.startOfDay(for: .now) ? .red : .secondary)
                }
                if let locationName {
                    Label(locationName, systemImage: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            if let note = entry.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
