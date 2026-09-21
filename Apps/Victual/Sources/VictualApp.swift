import SwiftUI
import VictualCore
import VictualUI

/// The application entry point.
///
/// The session is owned here and installed into the environment by ``RootView``,
/// so every screen reads one connection. `restore()` signs back in from the
/// Keychain when this instance has been used before, and returns `false`
/// without disturbing the session state when it has not.
@main
struct VictualApp: App {
    @State private var session = VictualSession(credentialStore: Self.credentialStore)

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task { await session.restore() }
        }
        .defaultSize(width: 1_100, height: 700)
        .commands {
            // Replaces the stock New Item command, which this application has
            // no equivalent of: stock is added by a booking against a product
            // that already exists.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(session: session)
        }
    }

    /// The application's own Keychain item namespace.
    ///
    /// Deliberately not the package default: a package test run and a shipped
    /// application would otherwise write the same generic-password item, and
    /// `removeAll()` in a test would take a real household's key with it.
    private static let credentialStore = KeychainCredentialStore(
        configuration: .init(service: "dev.victual.Victual.api-key")
    )
}
