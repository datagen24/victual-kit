#if DEBUG
import SwiftUI
import VictualHealth

/// Debug-only Settings rows: the HealthKit spike, and a switch that runs the
/// Medications screens against an in-memory server.
///
/// The real medication routes are not in the generated client until victual#700 and
/// the phone has no transport for them, so without this switch a debug build
/// offers no Medications screen to try. The demo server books nothing anywhere.
struct DebugSettingsSection: View {
    let workspace: PhoneWorkspace

    var body: some View {
        Section {
            MedicationSpikeLink()
            Toggle("Demo medication server", isOn: Bindable(workspace.medications).useDemoBackend)
        } header: {
            Text("Debug")
        } footer: {
            Text("The demo server is in memory and sends nothing off this phone. Turning it on or off rebuilds the medication screens.")
        }
        .onChange(of: workspace.medications.useDemoBackend) { _, _ in
            Task { await workspace.medications.prepare(client: workspace.client) }
        }
    }
}
#endif
