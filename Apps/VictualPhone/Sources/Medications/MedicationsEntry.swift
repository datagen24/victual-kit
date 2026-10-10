import SwiftUI
import VictualHealth
import VictualStock

/// The Settings rows for medication sync: a link when the server takes it, and
/// otherwise a line that says why there is none.
///
/// Absent on an OS before 26 or a device with no Health data, where it could never
/// work. Hidden while the server's answer is unknown, so no row flickers in and out.
struct MedicationsSettingsSection: View {
    let medications: MedicationsModel
    let capabilities: CapabilityGate

    var body: some View {
        if medications.isOfferable {
            Section {
                NavigationLink {
                    MedicationsScreen(medications: medications, capabilities: capabilities)
                } label: {
                    Label("Medications", systemImage: "pills")
                }
            } footer: {
                if let sync = medications.sync, let failure = sync.state.error {
                    Label("Medication doses are not being sent: \(failure.errorDescription ?? "sync failed")", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        } else if medications.serverTooOld {
            Section {
                Label("Medication sync needs a newer Victual server.", systemImage: "pills")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
