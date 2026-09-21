import SwiftUI
import VictualStock
import VictualUI

/// The application's main window.
///
/// Scaffold only: the sidebar names the status filters the server already
/// computes, and nothing reads stock yet. `GET /stock/volatile` returns due,
/// overdue, expired and below-minimum in one response, so four of these five
/// selections cost one request between them.
///
/// See `docs/plans/01-macos-stock-app.md` for what belongs here.
struct InventoryView: View {
    @Environment(\.victualSession) private var session

    @State private var filter: StockFilter = .all

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("Stock") {
                    ForEach(StockFilter.allCases) { filter in
                        Label(filter.title, systemImage: symbol(for: filter))
                            .tag(filter)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ContentUnavailableView(
                filter.title,
                systemImage: symbol(for: filter),
                description: Text("Nothing reads stock yet.")
            )
            .navigationTitle(filter.title)
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
