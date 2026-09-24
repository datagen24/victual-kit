import SwiftUI
import VictualCore
import VictualStock
import VictualUI

/// The connection form until there is a connection, and the tabs after.
///
/// The workspace is rebuilt whenever the session's client changes, for the
/// reason the macOS application's `RootView` gives: a reconnect with a rotated
/// key is a new client wearing the same server, and a workspace holding the old
/// one would go on using a credential the server has stopped accepting.
struct RootView: View {
    let session: VictualSession

    @State private var workspace: PhoneWorkspace?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.state.isConnected, let workspace {
                MainTabs(workspace: workspace, session: session)
            } else if session.state.isConnected {
                ProgressView()
            } else {
                NavigationStack {
                    VictualConnectionView(session: session)
                        .navigationTitle("Connect")
                }
            }
        }
        .victualSession(session)
        .onChange(of: session.connectionGeneration) { _, _ in syncWorkspace() }
        .onAppear(perform: syncWorkspace)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: workspace?.resume()
            case .background: workspace?.stop()
            default: break
            }
        }
    }

    private func syncWorkspace() {
        workspace?.stop()
        guard let client = session.client else {
            workspace = nil
            return
        }
        workspace = PhoneWorkspace(client: client)
    }
}

/// Scan, stock, and the connection, in that order: scanning is what the phone
/// is for, so it is the tab the app opens on.
private struct MainTabs: View {
    let workspace: PhoneWorkspace
    let session: VictualSession

    var body: some View {
        TabView {
            Tab("Scan", systemImage: "barcode.viewfinder") {
                ScanScreen(workspace: workspace)
            }
            Tab("Stock", systemImage: "shippingbox") {
                StockScreen(workspace: workspace)
            }
            Tab("Settings", systemImage: "gear") {
                SettingsScreen(session: session)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { credentialWarning }
        .task { await workspace.start() }
        .sheet(item: Bindable(workspace).presentedBooking) { presentation in
            BookingForm(presentation: presentation, workspace: workspace)
        }
        .alert(
            "That did not work",
            isPresented: Binding(
                // While a booking form is up, the form reports its own errors.
                get: { workspace.bookings.error != nil && workspace.presentedBooking == nil },
                set: { if !$0 { workspace.bookings.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { workspace.bookings.clearError() }
        } message: {
            Text(workspace.bookings.error?.errorDescription ?? "")
        }
    }

    /// Says so when the API key could not be saved.
    ///
    /// The macOS application's lesson carried over: the connection form is the
    /// only other place a Keychain failure shows, and it is replaced the moment
    /// the connection succeeds — so without this the first symptom would be
    /// retyping the key at the next launch, unexplained.
    @ViewBuilder
    private var credentialWarning: some View {
        if let error = session.credentialStoreError {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("This key was not saved and will be asked for again next launch.")
                    Text(error.errorDescription ?? "The Keychain refused it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

/// The instance, the key, and both ways out: disconnect, which keeps the key,
/// and forget, which removes it.
private struct SettingsScreen: View {
    let session: VictualSession

    var body: some View {
        NavigationStack {
            VictualConnectionView(session: session)
                .navigationTitle("Settings")
        }
    }
}

/// The undo affordance, shared by every screen that books.
///
/// A bar, not a toast, for the reason the macOS application gives: someone
/// who has just consumed the wrong thing should not be racing a timer.
struct UndoBar: View {
    let bookings: BookingController
    let onUndo: () async -> Void

    var body: some View {
        if bookings.canUndoLast, let action = bookings.lastAction {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(action.title) recorded.")
                    .lineLimit(1)
                Spacer()
                Button("Undo") { Task { await onUndo() } }
                    .buttonStyle(.bordered)
                Button {
                    bookings.dismissUndo()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss")
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
