import SwiftUI
import VictualCore
import VictualHealth
import VictualStock

/// First-run setup, one medication at a time.
///
/// Three cases, from plan 03:
/// 1. **In Health and in Victual**: map it (the same editor as the list).
/// 2. **In Health, not in Victual**: say what is missing and hand off to the web
///    UI. This wizard writes no master data: a product or unit conversion needs
///    the household's `MASTER_DATA_EDIT` right (victual#742).
/// 3. **In Victual, not in Health**: nothing syncs; consume by hand with a
///    consumption recipe. Said on the first and last page.
///
/// Each medication settles on its own and the wizard can be left half done; what is
/// not settled stays "needs mapping".
struct SetupWizard: View {
    let setup: MedicationSetupStore
    let capabilities: CapabilityGate
    let webURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var queue: [String] = []
    @State private var started = false
    @State private var position = 0

    var body: some View {
        NavigationStack {
            Group {
                if !started {
                    IntroPage(webURL: webURL, count: setup.unsettled.count) {
                        queue = setup.unsettled.map(\.id)
                        started = true
                    }
                } else if position < queue.count, let item = setup.items.first(where: { $0.id == queue[position] }) {
                    ItemPage(
                        setup: setup, item: item, capabilities: capabilities, webURL: webURL,
                        step: position + 1, of: queue.count
                    ) { position += 1 }
                    .id(item.id)
                } else {
                    DonePage(setup: setup, webURL: webURL)
                }
            }
            .navigationTitle("Set up medications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(started && position >= queue.count ? "Close" : "Leave for later") { dismiss() }
                }
            }
        }
    }
}

private struct IntroPage: View {
    let webURL: URL?
    let count: Int
    let begin: () -> Void

    var body: some View {
        Form {
            Section {
                Text(count == 0
                    ? "Every medication you share is already settled. You can run this again after sharing more in Health."
                    : "\(count) medication\(count == 1 ? "" : "s") shared from Health still need a decision.")
            }
            Section("Before you map anything") {
                Text("In Victual's web UI, create a product for each medication, with its stock quantity unit.")
                Text("If a dose is counted in a unit other than the stock unit (a tablet from a box, say), add a unit conversion from it to the stock unit.")
                Text("Put the product in the organizer you take it from.")
            }
            Section {
                Text("This app cannot create products or conversions: that takes the household administrator's rights. It also never guesses a product from a medication's name.")
                Text("Things in Victual that are not in Health do not sync. Take those out of stock by hand, with a consumption recipe.")
            } header: {
                Text("What this does not do")
            }
            if let webURL {
                Section { Link("Open Victual in the browser", destination: webURL) }
            }
            Section {
                Button("Start") { begin() }.disabled(count == 0)
            }
        }
    }
}

private struct ItemPage: View {
    let setup: MedicationSetupStore
    let item: SetupItem
    let capabilities: CapabilityGate
    let webURL: URL?
    let step: Int
    let of: Int
    let next: () -> Void

    @State private var missing: Set<MissingInVictual> = []
    @State private var choosingMissing = false

    var body: some View {
        Form {
            Section {
                Text(item.medication.displayName).font(.title3.bold())
            } header: {
                Text("\(step) of \(of)")
            }

            Section("Is it in Victual?") {
                NavigationLink("Yes: map it to a product or recipe") {
                    MappingEditor(setup: setup, item: item, capabilities: capabilities, onSaved: next)
                }
                Button("Not yet: it is missing in Victual") { choosingMissing.toggle() }
                Button("It is not worth syncing: skip it") {
                    Task {
                        await setup.decide(.skipped, for: item.id)
                        next()
                    }
                }
                Button("Decide later") { next() }
            }

            if choosingMissing {
                Section {
                    ForEach(MissingInVictual.allCases, id: \.self) { kind in
                        Toggle(kind.checklistTitle, isOn: Binding(
                            get: { missing.contains(kind) },
                            set: { if $0 { missing.insert(kind) } else { missing.remove(kind) } }
                        ))
                    }
                    if let webURL { Link("Open Victual in the browser", destination: webURL) }
                    Button("Remember what is missing") {
                        Task {
                            await setup.decide(.waitingForVictual(missing: MissingInVictual.allCases.filter(missing.contains)), for: item.id)
                            next()
                        }
                    }
                } header: {
                    Text("What does Victual lack?")
                } footer: {
                    Text("Create these in Victual's web UI. Then open this wizard again from Medications, or map it from the list. Nothing is created from here.")
                }
            }
        }
    }
}

extension MissingInVictual {
    fileprivate var checklistTitle: String {
        switch self {
        case .product: "A product for this medication"
        case .unitConversion: "A unit conversion to its stock unit"
        case .location: "The organizer it is kept in"
        }
    }
}

private struct DonePage: View {
    let setup: MedicationSetupStore
    let webURL: URL?

    var body: some View {
        Form {
            Section("Where things stand") {
                LabeledContent("Mapped", value: "\(setup.active.filter { if case .mapped = $0.status { true } else { false } }.count)")
                LabeledContent("Waiting for Victual", value: "\(setup.active.filter { if case .waitingForVictual = $0.status { true } else { false } }.count)")
                LabeledContent("Not synced", value: "\(setup.active.filter { $0.status == .skipped }.count)")
                LabeledContent("Still undecided", value: "\(setup.unsettled.count)")
            }
            Section {
                Text("Undecided medications show as \u{201C}Needs mapping\u{201D} and nothing is sent for them.")
                Text("Items that are in Victual but not in Health never sync. Take them out of stock by hand with a consumption recipe.")
            }
        }
    }
}
