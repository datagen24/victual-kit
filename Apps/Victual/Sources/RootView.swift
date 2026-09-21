import SwiftUI
import VictualUI

/// Shows the inventory once a connection exists, and the connection form until
/// then.
///
/// The session goes into the environment on both branches: the connection form
/// takes it directly, but a sheet or an inspector presented over the form still
/// finds it there.
struct RootView: View {
    let session: VictualSession

    var body: some View {
        Group {
            if session.state.isConnected {
                InventoryView()
            } else {
                VictualConnectionView(session: session)
                    .formStyle(.grouped)
                    .frame(minWidth: 460, minHeight: 360)
            }
        }
        .victualSession(session)
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
