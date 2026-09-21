import SwiftUI
import VictualCore
import VictualStock
import VictualUI

/// The application's main window.
///
/// Three columns. The sidebar holds the server's own status buckets and the
/// locations tree; the content column is the stock table; the detail column is
/// the product inspector. `GET /stock/volatile` returns due, overdue, expired
/// and below-minimum in one response, so four of the five status entries cost
/// one request between them.
struct InventoryView: View {
    @Bindable var workspace: StockWorkspace

    /// Optional because that is the only shape `List`'s single-selection
    /// initializer takes. A sidebar with nothing selected is reachable — click
    /// the empty space below the rows — so the scope falls back rather than
    /// leaving the table blank.
    @State private var sidebarSelection: StockScope? = .status(.all)
    @State private var selectedProduct: Int?

    var body: some View {
        // A local `@Bindable` because the stores are `let` on the workspace:
        // the binding has to be taken from the observable object itself.
        @Bindable var stock = workspace.stock

        return NavigationSplitView {
            sidebar
        } content: {
            StockTable(
                store: workspace.stock,
                showsPrices: workspace.capabilities.canSeePrices,
                selection: $selectedProduct
            )
            .navigationTitle(scopeTitle)
            .navigationSubtitle(subtitle)
            .searchable(text: $stock.searchText, placement: .toolbar, prompt: "Search stock")
            .toolbar { toolbar }
            .navigationSplitViewColumnWidth(min: 360, ideal: 560)
        } detail: {
            ProductInspector(
                store: workspace.detail,
                showsPrices: workspace.capabilities.canSeePrices,
                locationName: { workspace.stock.location($0)?.path ?? workspace.stock.location($0)?.displayName }
            )
        }
        .task { await workspace.start() }
        .onDisappear { workspace.stop() }
        .onChange(of: sidebarSelection) { _, new in
            workspace.stock.scope = new ?? .status(.all)
        }
        .onChange(of: selectedProduct) { _, new in
            workspace.detail.select(new)
        }
        .safeAreaInset(edge: .bottom) { undoBar }
        .sheet(item: $workspace.presentedBooking) { action in
            BookingSheet(
                action: action,
                product: workspace.detail.detail,
                productID: workspace.bookingTarget ?? workspace.detail.productID ?? 0,
                store: workspace.stock,
                onCommit: { await workspace.perform($0) }
            )
        }
        .alert(
            "That did not work",
            isPresented: Binding(
                get: { workspace.bookings.error != nil },
                set: { if !$0 { workspace.bookings.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { workspace.bookings.clearError() }
        } message: {
            Text(workspace.bookings.error?.errorDescription ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Stock") {
                ForEach(StockFilter.allCases) { filter in
                    Label(filter.title, systemImage: symbol(for: filter))
                        .badge(workspace.stock.count(of: filter))
                        .tag(StockScope.status(filter))
                }
            }

            if !workspace.stock.locations.isEmpty {
                Section("Locations") {
                    ForEach(LocationNode.forest(from: workspace.stock.locations)) { node in
                        LocationRows(node: node)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
    }

    // MARK: - Toolbar and status

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                BookingButtons(workspace: workspace)
            } label: {
                Label("Book", systemImage: "plusminus.circle")
            }
            .help("Record consuming, buying, opening, correcting or moving stock.")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await workspace.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(workspace.stock.state.isLoading)
        }
    }

    private var scopeTitle: String {
        switch workspace.stock.scope {
        case .status(let filter): filter.title
        case .location(let id):
            workspace.stock.location(id)?.path ?? workspace.stock.location(id)?.displayName
                ?? "Location"
        }
    }

    private var subtitle: String {
        if workspace.stock.state.isLoading { return "Refreshing…" }
        if let error = workspace.stock.state.error {
            return error.errorDescription ?? "Could not read stock"
        }
        let count = workspace.stock.rows.count
        var text = "\(count) \(count == 1 ? "product" : "products")"
        if workspace.capabilities.isReadOnlyKey { text += " · read-only key" }
        return text
    }

    /// The undo affordance, shown only while there is a transaction to undo.
    ///
    /// A bar rather than a transient toast: a household member who has just
    /// consumed the wrong thing should not be racing a timer to put it back.
    @ViewBuilder
    private var undoBar: some View {
        if workspace.bookings.canUndoLast, let action = workspace.bookings.lastAction {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(action.title) recorded.")
                Spacer()
                Button("Undo") { Task { await workspace.undoLastBooking() } }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Dismiss") { workspace.bookings.dismissUndo() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom))
        }
    }

    private func symbol(for filter: StockFilter) -> String {
        switch filter {
        case .all: "shippingbox"
        case .dueSoon: "clock"
        case .overdue: "exclamationmark.triangle"
        case .expired: "xmark.octagon"
        case .belowMinimum: "cart.badge.plus"
        }
    }
}

/// One location and, recursively, what is inside it.
private struct LocationRows: View {
    let node: LocationNode

    var body: some View {
        if let children = node.children {
            DisclosureGroup {
                ForEach(children) { child in
                    LocationRows(node: child)
                }
            } label: {
                Label(node.name, systemImage: "archivebox")
                    .tag(StockScope.location(node.id))
            }
        } else {
            Label(node.name, systemImage: "archivebox")
                .tag(StockScope.location(node.id))
        }
    }
}

/// The five booking commands, wherever they are shown.
///
/// Disabled with a tooltip naming the missing permission, never hidden. A
/// household member should be able to see that consume exists and that they
/// lack `STOCK_CONSUME`; a control that vanishes teaches nothing.
struct BookingButtons: View {
    let workspace: StockWorkspace

    var body: some View {
        ForEach(StockAction.allCases) { action in
            Button(action.title) { workspace.beginBooking(action) }
                .disabled(!workspace.canBegin(action))
                .help(workspace.reason(action) ?? action.title)
        }
    }
}
