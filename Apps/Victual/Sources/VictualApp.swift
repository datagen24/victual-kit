import SwiftUI
import VictualUI

/// The application entry point.
///
/// The session is owned here and installed into the environment by ``RootView``,
/// so every screen reads one connection. `restore()` signs back in from the
/// Keychain when this instance has been used before, and returns `false`
/// without disturbing the session state when it has not.
@main
struct VictualApp: App {
    @State private var session = VictualSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task { await session.restore() }
        }
        .defaultSize(width: 1_100, height: 700)

        Settings {
            SettingsView(session: session)
        }
    }
}
