import SwiftUI
import VictualCore
import VictualUI

/// The iPhone application's entry point.
///
/// Same shape as the macOS application's: one session, owned here, restored
/// from the Keychain at launch, and handed to ``RootView``.
@main
struct VictualPhoneApp: App {
    @State private var session = VictualSession(credentialStore: Self.credentialStore)

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task { await session.restore() }
        }
    }

    /// The application's own Keychain namespace.
    ///
    /// Not the package default, for the reason the macOS application gives: a
    /// test run must never share an item with a real household's key.
    ///
    /// ## Why `afterFirstUnlock`
    ///
    /// The Siri concept (docs/concepts/siri-and-app-intents.md §6.2) names two
    /// settings that silently break background work if left at their defaults.
    /// This is the first: an intent or a refresh firing after a reboot, before
    /// the phone is unlocked, cannot read a `whenUnlocked` item. Changing
    /// accessibility later is a migration, since the existing item keeps the
    /// class it was written with, so it is set now while there is nothing to
    /// migrate.
    ///
    /// The second, a shared access group, is deliberately not set: it needs a
    /// team identifier, which this project does not commit, and there is no
    /// extension yet to share with.
    ///
    /// Unlike the Mac, the data-protection Keychain stays on. iOS has no other,
    /// and a simulator build holds the access group it needs.
    private static let credentialStore = KeychainCredentialStore(
        configuration: .init(
            service: "dev.victual.VictualPhone.api-key",
            accessibility: .afterFirstUnlock
        )
    )
}
