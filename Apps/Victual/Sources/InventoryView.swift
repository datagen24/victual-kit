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

    /// Optional because that is the only shape `List`'s single-selection
    /// initializer takes. A sidebar with nothing selected is reachable — click
    /// the empty space below the rows — so ``filter`` falls back rather than
    /// leaving the detail column blank.
    @State private var selection: StockFilter? = .all

    private var filter: StockFilter { selection ?? .all }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Stock") {
                    ForEach(StockFilter.allCases) { candidate in
                        Label(candidate.title, systemImage: symbol(for: candidate))
                            .tag(candidate)
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
