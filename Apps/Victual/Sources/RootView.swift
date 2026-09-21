import SwiftUI
import VictualCore
import VictualStock
import VictualUI

/// Shows the inventory once a connection exists, and the connection form until
/// then.
///
/// The workspace is rebuilt when the session connects to a different instance,
/// and torn down when it disconnects: a window must never show one household's
/// stock under another's connection.
struct RootView: View {
    let session: VictualSession

    @State private var workspace: StockWorkspace?

    var body: some View {
        Group {
            if session.state.isConnected, let workspace {
                InventoryView(workspace: workspace)
                    .safeAreaInset(edge: .top) { credentialWarning }
            } else if session.state.isConnected {
                // Connected, but the workspace has not been built yet — one
                // frame at most.
                ProgressView().controlSize(.large)
            } else {
                VictualConnectionView(session: session)
                    .formStyle(.grouped)
                    .frame(minWidth: 460, minHeight: 360)
            }
        }
        .victualSession(session)
        // The generation, not the address: reconnecting to the same instance
        // with a rotated key is a new client wearing the same server.
        .onChange(of: session.connectionGeneration) { _, _ in syncWorkspace() }
        .onAppear(perform: syncWorkspace)
    }

    /// Says so when the API key could not be saved.
    ///
    /// The session keeps this apart from its connection state on purpose — a key
    /// that could not be stored is not a broken session — but that is exactly
    /// how it goes unnoticed: the connection form, which is where the error is
    /// otherwise visible, is replaced the instant the connection succeeds. The
    /// first symptom would then be retyping the key at the next launch, with no
    /// explanation offered.
    @ViewBuilder
    private var credentialWarning: some View {
        if let error = session.credentialStoreError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This key was not saved, and will have to be entered again next launch.")
                    Text(error.errorDescription ?? "The Keychain refused the request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// Keeps the workspace matched to the session's current client.
    ///
    /// Rebuilds whenever the client changes at all, rather than only when the
    /// address does. A reconnect to the same instance hands back a different
    /// client — a rotated key, most obviously — and a workspace holding the old
    /// one would go on using a credential the server has stopped accepting.
    private func syncWorkspace() {
        workspace?.stop()
        guard let client = session.client else {
            workspace = nil
            return
        }
        workspace = StockWorkspace(client: client)
    }
}

/// The Settings scene.
///
/// `VictualConnectionView` already renders the instance address, the key field,
/// the connection status and both of the session's exit paths — disconnect,
/// which keeps the stored key, and forget, which removes it. Reusing it here
/// means the two places a connection can be changed cannot drift apart.
struct SettingsView: View {
    let session: VictualSession

    var body: some View {
        VictualConnectionView(session: session)
            .formStyle(.grouped)
            .frame(width: 480, height: 400)
    }
}
