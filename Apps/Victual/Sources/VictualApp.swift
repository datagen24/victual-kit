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
        // No `id:` on the group, and no `.commands` touching `.newItem`. Both
        // were tried and both made things worse: replacing the `.newItem` group
        // removes File > New Window along with it, and giving the group an id
        // makes it restore a persisted set of windows — which, once that set is
        // empty, means launching with no window and no way to open one.
        WindowGroup {
            RootView(session: session)
                .task { await session.restore() }
        }
        .defaultSize(width: 1_100, height: 700)

        Settings {
            SettingsView(session: session)
        }
    }

    /// The application's own Keychain item namespace.
    ///
    /// Deliberately not the package default: a package test run and a shipped
    /// application would otherwise write the same generic-password item, and
    /// `removeAll()` in a test would take a real household's key with it.
    ///
    /// ## Why the data-protection Keychain is off
    ///
    /// It requires the process to hold a Keychain access group, which comes from
    /// a signing identity's team. This application is ad-hoc signed
    /// (`CODE_SIGN_IDENTITY` is `-`, `TeamIdentifier=not set`), so it has none,
    /// and `SecItemAdd` answers `errSecMissingEntitlement`. That failure is not
    /// fatal — the session stays connected — but nothing is saved, so the next
    /// launch has nothing to restore and the user retypes their key.
    ///
    /// Observed, not assumed: it is what made the relaunch check fail.
    ///
    /// The file-based Keychain has no such requirement and is the right store
    /// for an application signed this way. **Turn this back on when the
    /// application gets a real signing identity** — plan 01's open question 1 —
    /// because a Developer ID build does have a team, and the data-protection
    /// Keychain is the better store once it is usable.
    private static let credentialStore = KeychainCredentialStore(
        configuration: .init(
            service: "dev.victual.Victual.api-key",
            usesDataProtectionKeychain: false
        )
    )
}
