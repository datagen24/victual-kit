import SwiftUI
import VictualCore
import VictualHealth
import VictualStock

/// Events that need the person, from ``MedicationSyncStore/reviewRows``.
///
/// The reason a dose is held is shown as the server sent it. Nothing here
/// decides for the person: a deletion in Health is either undone or kept by their
/// choice, because the phone cannot tell a mistaken log from cleared history.
struct ReviewSection: View {
    let sync: MedicationSyncStore
    let setup: MedicationSetupStore
    let capabilities: CapabilityGate

    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        var medicationRef: String
        var count: Int
        var id: String { medicationRef }
    }

    var body: some View {
        if !sync.reviewRows.isEmpty {
            Section {
                ForEach(sync.reviewRows) { row in
                    rowView(row)
                }
            } header: {
                Text("Needs you")
            } footer: {
                if !capabilities.canConsume {
                    Text(capabilities.reason(.consume) ?? "This key cannot record consumption, so these cannot be decided here.")
                }
            }
            .confirmationDialog(
                "Doses deleted in Health",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { pending in
                Button("Undo them: put the stock back") {
                    Task { await sync.resolveDeletions(medicationRef: pending.medicationRef, action: .void) }
                }
                Button("Keep them: the doses were taken") {
                    Task { await sync.resolveDeletions(medicationRef: pending.medicationRef, action: .keep) }
                }
            } message: { pending in
                Text("\(pending.count) dose\(pending.count == 1 ? " was" : "s were") deleted in Health. Deleting a log does not say whether the pills were taken, so Victual kept the stock as it was. Undo restores it.")
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ReviewRow) -> some View {
        switch row {
        case .needsMapping(let ref):
            if let item = setup.items.first(where: { $0.id == ref }) {
                NavigationLink {
                    MappingEditor(setup: setup, item: item, capabilities: capabilities)
                } label: {
                    line("Doses of \(item.medication.displayName) are waiting for a mapping", detail: "Nothing has been sent for it.", symbol: "link")
                }
            } else {
                line("Doses from a medication that is no longer shared are waiting for a mapping", detail: "Share it again in Health, then map it.", symbol: "link")
            }

        case .sourceDeleted(let ref, let ids):
            VStack(alignment: .leading, spacing: 6) {
                line(
                    "\(setup.displayName(for: ref) ?? "A medication"): \(ids.count) dose\(ids.count == 1 ? "" : "s") deleted in Health",
                    detail: "Victual kept the stock as it was. Decide once for all of them.", symbol: "trash")
                Button("Decide…") { pendingDeletion = PendingDeletion(medicationRef: ref, count: ids.count) }
                    .buttonStyle(.bordered)
                    .disabled(!capabilities.canConsume)
            }

        case .unitUnconfirmed(let eventID, let label):
            VStack(alignment: .leading, spacing: 6) {
                line("Health calls the unit this:", detail: nil, symbol: "ruler")
                Text("\u{201C}\(label)\u{201D}").font(.body.monospaced())
                Text("Approve it if this is the unit you mapped the medication in.").font(.caption).foregroundStyle(.secondary)
                Button("Approve") { Task { await sync.approveUnit(eventID: eventID) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!capabilities.canConsume)
            }

        case .needsReview(_, let reason):
            line(
                "A dose was held: \(reason?.rawValue ?? "needs review")",
                detail: "As the server reported it. Resolve it in Victual's web UI.", symbol: "exclamationmark.circle")

        case .possibleDuplicate(_, let transactionIDs):
            line(
                "This dose may match \(transactionIDs.count) booking\(transactionIDs.count == 1 ? "" : "s") you entered by hand",
                detail: "Check the stock journal in Victual.", symbol: "doc.on.doc")
        }
    }

    private func line(_ title: String, detail: String?, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}
