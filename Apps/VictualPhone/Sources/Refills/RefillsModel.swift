import Foundation
import Observation
import VictualCore
import VictualHealth

/// Owns the ``RefillStore`` for one connection.
///
/// Refill dates come from the server and need neither HealthKit nor iOS 26, so
/// this works wherever the app does. Nothing is read until the server's
/// capabilities list the refill features.
@MainActor
@Observable
final class RefillsModel {
    private(set) var store: RefillStore?

    func prepare(client: VictualClient) async {
        let userID: Int
        do {
            userID = try await client.currentUserID()
        } catch {
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Refills", isDirectory: true)
        let store = RefillStore(
            source: VictualRefillService(client: client), notifications: SystemRefillNotificationCenter(),
            stateStore: FileRefillStateStore(directory: directory), server: client.server.baseURL.absoluteString,
            account: "user-\(userID)")
        self.store = store
        await store.refreshNotificationPermission()
        await store.refresh()
    }

    /// Launch and foreground: the only automatic refreshes.
    func foreground() async {
        await store?.refresh()
    }

    /// Cancels notifications and erases what this phone kept: sign-out, a removed key,
    /// or a different server.
    func revoke() async {
        await store?.revoke()
        store = nil
    }
}
