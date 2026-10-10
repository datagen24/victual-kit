import Foundation
import Observation
import VictualCore
import VictualHealth

/// What backs the Medications screens on this connection.
///
/// One per ``PhoneWorkspace``. It exists so the Settings entry can be decided
/// without touching HealthKit on any OS older than 26, and so nothing is read from
/// Health or sent until a person or a foreground event asks.
@MainActor
@Observable
final class MedicationsModel {
    /// Both stores, once they exist. `nil` on an OS or device that cannot run this,
    /// and until ``prepare(client:)`` has finished.
    private(set) var sync: MedicationSyncStore?
    private(set) var setup: MedicationSetupStore?
    /// Where the server's web UI is, for the wizard's hand-off.
    private(set) var webURL: URL?
    /// Why the stores could not be built (a failed `GET /user`), if that is why.
    private(set) var prepareError: VictualError?

    #if DEBUG
    /// Debug builds can run the screens against an in-memory server, since the
    /// real routes are not in the generated client yet. Never present in Release.
    var useDemoBackend: Bool = UserDefaults.standard.bool(forKey: MedicationsModel.demoKey) {
        didSet { UserDefaults.standard.set(useDemoBackend, forKey: Self.demoKey) }
    }
    private static let demoKey = "dev.victual.VictualPhone.demoMedicationBackend"
    #endif

    /// Whether the Settings entry is shown: the OS and Health allow it and the
    /// server answered that it takes medication events.
    var isOfferable: Bool { sync?.availability == .available }

    /// Set when the server is known not to take medication events, so Settings can
    /// say so instead of showing nothing.
    var serverTooOld: Bool { sync?.availability == .unavailable(.olderServer) }

    /// Builds the stores for `client`. Safe to call again after a reconnect.
    func prepare(client: VictualClient) async {
        guard #available(iOS 26, *), HealthKitDoseSource.isHealthDataAvailable else { return }
        let userID: Int
        do {
            userID = try await client.currentUserID()
        } catch {
            prepareError = error
            return
        }
        prepareError = nil

        let server = client.server.baseURL.absoluteString
        let account = "user-\(userID)"
        let source = HealthKitDoseSource()
        let directory = Self.directory

        let submitter: any ConsumptionEventSubmitter
        let mappingService: any ConsumptionMappingService
        let catalog: any MappingCatalog
        #if DEBUG
        if useDemoBackend {
            // The routes for events and mappings do not exist yet, so those are in
            // memory. What the editor reads (products, units, organizers) does
            // exist, so it reads the real instance and the demo maps real products.
            let demo = DemoMedicationBackend()
            (submitter, mappingService, catalog) = (demo, demo, VictualMappingCatalog(client: client))
        } else {
            let none = UnsupportedMedicationBackend()
            (submitter, mappingService, catalog) = (none, none, none)
        }
        #else
        let none = UnsupportedMedicationBackend()
        (submitter, mappingService, catalog) = (none, none, none)
        #endif

        let sync = MedicationSyncStore(
            source: source, submitter: submitter, directory: directory, server: server, account: account)
        let setup = MedicationSetupStore(
            medicationSource: source, mappingService: mappingService, catalog: catalog,
            decisionStore: FileSetupDecisionStore(directory: directory), sync: sync, server: server, account: account)
        self.sync = sync
        self.setup = setup
        self.webURL = client.server.instanceURL
        await sync.checkAvailability()
        if sync.availability == .available { await setup.load() }
    }

    /// Sync on launch and foreground, when the key may record consumption.
    ///
    /// Never on a timer and never in the background: whether Health wakes the app
    /// for dose events is the device spike's question.
    func foreground(canConsume: Bool) async {
        guard canConsume, let sync, sync.availability == .available else { return }
        await sync.sync()
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MedicationSync", isDirectory: true)
    }
}
