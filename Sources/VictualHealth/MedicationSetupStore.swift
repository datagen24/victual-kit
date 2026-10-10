import CryptoKit
import Foundation
import Observation
import VictualCore

/// What Victual lacks for a medication that Health has, as the person said it.
public enum MissingInVictual: String, CaseIterable, Sendable, Codable {
    case product
    case unitConversion
    case location
}

/// Where the person left an item in the setup wizard.
///
/// Only the two choices that are not a mapping are remembered: a mapping lives on
/// the server. An item with neither is simply unsettled, and the wizard can be
/// left half done.
public enum SetupDecision: Sendable, Equatable, Codable {
    /// In Health, not in Victual yet. Creating a product or unit conversion needs
    /// the household's `MASTER_DATA_EDIT` right (victual#742), so the app hands
    /// off to the web UI and writes none of it.
    case waitingForVictual(missing: [MissingInVictual])
    /// The person does not want this one synced.
    case skipped
}

/// Where each item stands.
public enum SetupStatus: Sendable, Equatable {
    case mapped(ConsumptionMapping)
    case waitingForVictual([MissingInVictual])
    case skipped
    /// Shown as "needs mapping"; nothing is sent for it.
    case unsettled
}

/// One medication and where it stands.
public struct SetupItem: Sendable, Equatable, Identifiable {
    public var medication: HealthMedication
    public var status: SetupStatus
    public var id: String { medication.ref }
}

/// Remembers wizard decisions between launches. Opaque refs only, no names.
public protocol SetupDecisionStore: Sendable {
    func load(server: String, account: String) async throws -> [String: SetupDecision]
    func save(_ decisions: [String: SetupDecision], server: String, account: String) async throws
}

/// Keeps decisions as a file per server and account, with the same file protection
/// as the sync queue.
public actor FileSetupDecisionStore: SetupDecisionStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(server: String, account: String) throws -> [String: SetupDecision] {
        do {
            return try JSONDecoder().decode([String: SetupDecision].self, from: Data(contentsOf: file(server, account)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
    }

    public func save(_ decisions: [String: SetupDecision], server: String, account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(decisions).write(to: file(server, account), options: FileSyncStateStore.writeOptions)
    }

    private func file(_ server: String, _ account: String) -> URL {
        let text = [server, account].joined(separator: "\u{1F}")
        let stem = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("setup-\(stem).json")
    }
}

/// An in-memory ``SetupDecisionStore`` for tests and previews.
public actor InMemorySetupDecisionStore: SetupDecisionStore {
    private var stored: [String: SetupDecision] = [:]

    public init() {}

    public func load(server: String, account: String) -> [String: SetupDecision] { stored }

    public func save(_ decisions: [String: SetupDecision], server: String, account: String) {
        stored = decisions
    }
}

/// What the setup wizard, the mapping editor and the Medications list read.
///
/// It joins three sources the client never reconciles by itself: the medications
/// Health shares, the mappings the server holds, and what the person decided in
/// the wizard. Matching a medication to a product is always the person's choice;
/// nothing here looks at a name except to display it.
///
/// It writes no master data: the only Victual write is a mapping, which needs
/// `STOCK_CONSUME`, and a product or conversion that does not exist yet is a note
/// to the person, not a request.
@MainActor
@Observable
public final class MedicationSetupStore {
    public private(set) var items: [SetupItem] = []
    public private(set) var loadState: SyncState = .idle
    /// A refusal to save or remove a mapping, for the editor to show.
    public private(set) var saveError: VictualError?

    private let medicationSource: any HealthMedicationSource
    private let mappingService: any ConsumptionMappingService
    private let catalog: any MappingCatalog
    private let decisionStore: any SetupDecisionStore
    private let sync: MedicationSyncStore
    private let server: String
    private let account: String
    private let zone: @Sendable () -> TimeZone
    private var mappings: [String: ConsumptionMapping] = [:]
    private var decisions: [String: SetupDecision] = [:]
    private var medications: [HealthMedication] = []

    public init(
        medicationSource: any HealthMedicationSource,
        mappingService: any ConsumptionMappingService,
        catalog: any MappingCatalog,
        decisionStore: any SetupDecisionStore,
        sync: MedicationSyncStore,
        server: String,
        account: String,
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.medicationSource = medicationSource
        self.mappingService = mappingService
        self.catalog = catalog
        self.decisionStore = decisionStore
        self.sync = sync
        self.server = server
        self.account = account
        self.zone = zone
    }

    /// Items still waiting for a decision. The wizard's work list.
    public var unsettled: [SetupItem] {
        items.filter { $0.status == .unsettled && !$0.medication.isArchived }
    }

    public var active: [SetupItem] { items.filter { !$0.medication.isArchived } }
    public var archived: [SetupItem] { items.filter(\.medication.isArchived) }

    /// The name to show for a reference, or `nil` if Health does not share it now.
    public func displayName(for ref: String) -> String? {
        medications.first { $0.ref == ref }?.displayName
    }

    /// Reads the medications Health shares and the server's mappings, and hands the
    /// mappings to the sync.
    public func load() async {
        loadState = .syncing
        do {
            medications = try await medicationSource.medications()
            let found = try await mappingService.mappings()
            mappings = Dictionary(found.map { ($0.medicationRef, $0) }) { _, last in last }
            decisions = try await decisionStore.load(server: server, account: account)
            loadState = .synced
        } catch {
            loadState = .failed(VictualError.mapping(error))
        }
        rebuild()
    }

    /// Health's medication sheet, then a reload. Only from an explicit tap.
    public func chooseMedications() async {
        do {
            try await medicationSource.requestMedicationAuthorization()
        } catch {
            loadState = .failed(VictualError.mapping(error))
            return
        }
        await load()
    }

    /// Saves a mapping for `ref`. Returns whether the server accepted it.
    @discardableResult
    public func save(_ draft: MappingDraft, for ref: String) async -> Bool {
        saveError = nil
        guard let input = draft.input(in: zone()) else { return false }
        do {
            mappings[ref] = try await mappingService.put(input, medicationRef: ref)
            decisions[ref] = nil
            try? await decisionStore.save(decisions, server: server, account: account)
            rebuild()
            return true
        } catch {
            saveError = VictualError.mapping(error)
            return false
        }
    }

    public func removeMapping(for ref: String) async {
        saveError = nil
        do {
            try await mappingService.delete(medicationRef: ref)
            mappings[ref] = nil
            rebuild()
        } catch {
            saveError = VictualError.mapping(error)
        }
    }

    public func clearSaveError() { saveError = nil }

    public func decide(_ decision: SetupDecision?, for ref: String) async {
        decisions[ref] = decision
        try? await decisionStore.save(decisions, server: server, account: account)
        rebuild()
    }

    /// Products, recipes, units and locations for the editor.
    public var catalogReader: any MappingCatalog { catalog }

    private func rebuild() {
        items = medications.map { medication in
            if let mapping = mappings[medication.ref] {
                return SetupItem(medication: medication, status: .mapped(mapping))
            }
            switch decisions[medication.ref] {
            case .waitingForVictual(let missing): return SetupItem(medication: medication, status: .waitingForVictual(missing))
            case .skipped: return SetupItem(medication: medication, status: .skipped)
            case nil: return SetupItem(medication: medication, status: .unsettled)
            }
        }
        sync.setMappings(MappingSet(mappings.values.compactMap(\.deviceMapping)))
    }
}
