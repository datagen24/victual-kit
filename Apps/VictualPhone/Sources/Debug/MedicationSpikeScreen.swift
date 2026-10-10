#if DEBUG
import SwiftUI
import UIKit
import VictualHealth

/// The toolbar entry to the HealthKit spike, present only in debug builds on a
/// device that could run it. Nothing else in the app references the spike.
struct MedicationSpikeLink: View {
    var body: some View {
        if #available(iOS 26, *), HealthKitDoseSource.isHealthDataAvailable {
            NavigationLink("HealthKit spike") { MedicationSpikeScreen() }
        }
    }
}

/// Plan 03 Phase 0, on the phone.
///
/// Authorizes medications, listens to the dose-event query and shows what arrives,
/// entirely on this device: it makes no network request and writes nothing to Health.
/// The names it shows are on this screen only; the report it exports has none.
@available(iOS 26, *)
struct MedicationSpikeScreen: View {
    @State private var spike = HealthKitSpike(directory: Self.directory)
    @State private var copied = false

    var body: some View {
        Form {
            environmentSection
            stepsSection
            medicationsSection
            eventsSection
            revocationSection
            reportSection
        }
        .navigationTitle("HealthKit spike")
        .navigationBarTitleDisplayMode(.inline)
        .task { await spike.refreshMedications() }
        .onDisappear { spike.stopObserving() }
    }

    private var environmentSection: some View {
        let environment = SpikeEnvironment.current()
        return Section {
            LabeledContent("Device", value: environment.deviceModel)
            LabeledContent("OS", value: environment.osVersion)
            if let error = spike.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } footer: {
            Text("Local only. No request leaves this screen and nothing is written to Health.")
        }
    }

    private var stepsSection: some View {
        Section("Steps") {
            Button("1. Choose medications…") { Task { await spike.requestAuthorization() } }
            Button(spike.isObserving ? "2. Stop listening" : "2. Start listening") {
                if spike.isObserving { spike.stopObserving() } else { spike.startObserving() }
            }
            Button("3. Try background delivery") { Task { await spike.enableBackgroundDelivery() } }
            if let result = spike.backgroundDelivery {
                Text("Background delivery: \(result)").font(.footnote).foregroundStyle(.secondary)
            }
            Button("4. Re-query after revoking one") { Task { await spike.requeryAfterRevocation() } }
            Button("Clear events", role: .destructive) { spike.clearEvents() }
        }
    }

    private var medicationsSection: some View {
        Section("Medications (\(spike.medications.count))") {
            ForEach(spike.medications, id: \.label) { med in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(med.label)  \(spike.displayNames[med.label] ?? "")").font(.headline)
                    Text("form \(med.generalForm) · archived \(med.isArchived ? "yes" : "no") · scheduled \(med.hasSchedule ? "yes" : "no")")
                    Text("description: \(med.descriptionContainsName ? "(contains name)" : med.candidates.description ?? "nil") · valid \(med.candidates.descriptionIsValid ? "yes" : "no")")
                    Text("hash: \(med.candidates.hashed)").lineLimit(2)
                    Text("archive repeatable \(med.archiveRepeatable ? "yes" : "no") · round-trips \(med.archiveRoundTrips ? "yes" : "no")")
                    Text("same as last launch: description \(Self.seen(med.descriptionSeenLastLaunch)), hash \(Self.seen(med.hashSeenLastLaunch))")
                }
                .font(.caption)
            }
        }
    }

    private var eventsSection: some View {
        Section("Events (\(spike.events.count))") {
            ForEach(Array(spike.events.enumerated()), id: \.offset) { _, event in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.kind.rawValue) id#\(event.shortID) \(event.medicationLabel ?? "?") \(event.initialDelivery ? "(initial)" : "(update)")")
                        .font(.subheadline)
                    if event.kind == .inserted {
                        Text("\(event.status ?? "?") · \(event.scheduleType ?? "?") · dose \(Self.number(event.doseQuantity)) · unit \"\(event.unitString ?? "nil")\"")
                        if let seconds = event.secondsAfterStart, !event.initialDelivery {
                            Text("\(Int(seconds.rounded())) s after start")
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var revocationSection: some View {
        if !spike.revocations.isEmpty {
            Section("After revoking") {
                ForEach(Array(spike.revocations.enumerated()), id: \.offset) { _, r in
                    Text("medications \(r.medicationsBefore) → \(r.medicationsAfter), vanished \(r.vanished.joined(separator: ",")); delta +\(r.deltaAdded) −\(r.deltaDeleted); fresh \(r.freshRead)")
                        .font(.caption)
                }
            }
        }
    }

    private var reportSection: some View {
        Section {
            ShareLink("Share report", item: spike.report())
            Button(copied ? "Copied" : "Copy report") {
                UIPasteboard.general.string = spike.report()
                copied = true
            }
        } footer: {
            Text("Plain text with no medication names or nicknames: opaque references, quantities, units, statuses, and times to the minute.")
        }
    }

    private static func seen(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "n/a" }

    private static func number(_ value: Double?) -> String { value.map { String($0) } ?? "nil" }

    /// Where the opaque cross-launch comparison file lives.
    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HealthKitSpike", isDirectory: true)
    }
}
#endif
