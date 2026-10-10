import SwiftUI
import VictualHealth

/// The Settings row for refills: a link when the server lists the refill features,
/// a line saying why not when it lacks them.
struct RefillsSettingsSection: View {
    let refills: RefillsModel

    var body: some View {
        if let store = refills.store {
            switch store.availability {
            case .available:
                Section {
                    NavigationLink {
                        RefillsScreen(store: store)
                    } label: {
                        Label("Refills", systemImage: "calendar.badge.clock")
                    }
                } footer: {
                    if let failure = store.state.error {
                        Label(failure.errorDescription ?? "Refresh failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            case .unavailable(.missingFeatures(let missing)):
                Section {
                    Label("This server lacks what refills need: \(missing.joined(separator: ", ")).", systemImage: "calendar.badge.clock")
                        .foregroundStyle(.secondary)
                }
            case .unavailable(.olderServer):
                Section {
                    Label("Refills need a newer Victual server.", systemImage: "calendar.badge.clock").foregroundStyle(.secondary)
                }
            case .unknown:
                EmptyView()
            }
        }
    }
}
