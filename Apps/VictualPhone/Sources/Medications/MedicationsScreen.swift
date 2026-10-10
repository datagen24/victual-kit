import SwiftUI
import VictualCore
import VictualHealth
import VictualStock

/// Medication sync: its status, each medication, and what needs the person.
///
/// Medication names appear here, on the screen, and nowhere else: they are never
/// logged, saved by the app or sent to the server.
struct MedicationsScreen: View {
    let medications: MedicationsModel
    let capabilities: CapabilityGate

    var body: some View {
        if let sync = medications.sync, let setup = medications.setup {
            MedicationsContent(sync: sync, setup: setup, capabilities: capabilities, webURL: medications.webURL)
        } else {
            ContentUnavailableView("Medications are not available", systemImage: "pills")
        }
    }
}

private struct MedicationsContent: View {
    let sync: MedicationSyncStore
    let setup: MedicationSetupStore
    let capabilities: CapabilityGate
    let webURL: URL?

    @State private var wizardShown = false

    var body: some View {
        List {
            if !capabilities.canConsume {
                Section {
                    Label(
                        capabilities.reason(.consume) ?? "This key cannot record consumption.",
                        systemImage: "lock.fill")
                } footer: {
                    Text("Doses are not sent and mappings cannot be saved until the key can record consumption.")
                }
            }
            SyncStatusSection(sync: sync, capabilities: capabilities)
            accessLostSection
            ReviewSection(sync: sync, setup: setup, capabilities: capabilities)
            medicationsSection
            archivedSection
        }
        .navigationTitle("Medications")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { if capabilities.canConsume { await sync.sync() } }
        .task { await setup.load() }
        .sheet(isPresented: $wizardShown) {
            SetupWizard(setup: setup, capabilities: capabilities, webURL: webURL)
        }
    }

    private var medicationsSection: some View {
        Section {
            ForEach(setup.active) { item in
                NavigationLink {
                    MappingEditor(setup: setup, item: item, capabilities: capabilities)
                } label: {
                    ItemRow(item: item)
                }
            }
            Button("Choose medications…") { Task { await setup.chooseMedications() } }
            Button("Set up…") { wizardShown = true }
        } header: {
            Text("Medications")
        } footer: {
            Text("Only the medications you share with Victual in Health appear here. Victual never picks a product for you.")
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        if !setup.archived.isEmpty {
            Section("Archived in Health") {
                ForEach(setup.archived) { item in
                    NavigationLink {
                        MappingEditor(setup: setup, item: item, capabilities: capabilities)
                    } label: {
                        ItemRow(item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var accessLostSection: some View {
        if !sync.unavailableMedications.isEmpty {
            Section {
                Label("A medication you had mapped is no longer shared with Victual.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Choose medications…") { Task { await setup.chooseMedications() } }
            } footer: {
                Text("Its past doses were left alone. Share it again in Health to resume.")
            }
        }
    }
}

private struct ItemRow: View {
    let item: SetupItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.medication.displayName)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch item.status {
        case .mapped: "Mapped"
        case .waitingForVictual(let missing):
            "Waiting for Victual: " + missing.map(\.phrase).joined(separator: ", ")
        case .skipped: "Not synced"
        case .unsettled: "Needs mapping"
        }
    }
}

extension MissingInVictual {
    /// How the wizard names what Victual lacks.
    var phrase: String {
        switch self {
        case .product: "the product"
        case .unitConversion: "a unit conversion"
        case .location: "an organizer location"
        }
    }
}

/// "Last synced", and an unmistakable failure state.
///
/// Sync that fails silently when the API key lapses is the failure this exists to
/// prevent, so a `401` or `403` is not a line of grey text.
private struct SyncStatusSection: View {
    let sync: MedicationSyncStore
    let capabilities: CapabilityGate

    var body: some View {
        Section {
            if let error = sync.state.error {
                failure(error)
            } else {
                HStack {
                    if case .syncing = sync.state { ProgressView() }
                    Text(summary)
                }
            }
            if sync.heldCount > 0 {
                Label(
                    "\(sync.heldCount) dose\(sync.heldCount == 1 ? " was" : "s were") refused by the server and will not be retried.",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .foregroundStyle(.red)
            }
            Button("Sync now") { Task { await sync.sync() } }
                .disabled(!capabilities.canConsume || isSyncing)
        } header: {
            Text("Sync")
        } footer: {
            Text("Doses sync when the app opens, when it returns to the front, when you pull to refresh, and when you press the button.")
        }
    }

    private var isSyncing: Bool {
        if case .syncing = sync.state { true } else { false }
    }

    private var summary: String {
        if case .syncing = sync.state { return "Syncing…" }
        guard let last = sync.lastSynced else { return "Not synced yet" }
        return "Last synced \(last.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder
    private func failure(_ error: VictualError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline(error), systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(detail(error))
            if let last = sync.lastSynced {
                Text("Last synced \(last.formatted(.relative(presentation: .named))).").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func headline(_ error: VictualError) -> String {
        switch error {
        case .unauthorized: "Doses are NOT being sent: the server rejected your API key"
        case .forbidden: "Doses are NOT being sent: this key may not record consumption"
        default: "The last sync failed"
        }
    }

    private func detail(_ error: VictualError) -> String {
        switch error {
        case .unauthorized:
            "The key was refused (401). It may have expired or been deleted. Doses you log in Health stay queued on this phone. Reconnect with a working key in Settings."
        case .forbidden:
            "The server refused (403). Ask whoever runs Victual to allow this key to record consumption. Doses stay queued on this phone."
        default:
            (error.errorDescription ?? "Unknown error.") + " Unsent doses are queued and will be retried."
        }
    }
}
