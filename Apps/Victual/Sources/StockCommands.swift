import SwiftUI
import VictualStock

/// The Stock menu: refresh and the five bookings, for whichever window is in front.
///
/// Commands live outside any window, so they reach a window's workspace through
/// a focused scene value that ``InventoryView`` publishes. With no inventory
/// window in front — the connection form, say — the workspace is `nil` and every
/// item is disabled.
struct StockCommands: Commands {
    @FocusedValue(\.stockWorkspace) private var workspace

    var body: some Commands {
        CommandMenu("Stock") {
            Button("Refresh") {
                guard let workspace else { return }
                Task { await workspace.refreshAll() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(workspace == nil || workspace?.stock.state.isLoading == true)

            Divider()

            if let workspace {
                BookingButtons(workspace: workspace)
            } else {
                ForEach(StockAction.allCases) { action in
                    Button(action.title) {}.disabled(true)
                }
            }
        }
    }
}

private struct StockWorkspaceKey: FocusedValueKey {
    typealias Value = StockWorkspace
}

extension FocusedValues {
    /// The workspace of the inventory window in front, if there is one.
    var stockWorkspace: StockWorkspace? {
        get { self[StockWorkspaceKey.self] }
        set { self[StockWorkspaceKey.self] = newValue }
    }
}
