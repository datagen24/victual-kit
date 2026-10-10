import SwiftUI
import VictualCore
import VictualHealth
import VictualStock

/// Maps one medication to a Victual product or consumption recipe.
///
/// Every choice is the person's. The client does not match the medication's name
/// to a product, infer a unit conversion from a strength, or pick an organizer;
/// the lists come from the server and nothing here sends the name anywhere.
struct MappingEditor: View {
    let setup: MedicationSetupStore
    let item: SetupItem
    let capabilities: CapabilityGate
    /// Called after the server accepted the mapping.
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MappingDraft
    @State private var products: [CatalogItem] = []
    @State private var recipes: [CatalogItem] = []
    @State private var units: [CatalogUnit] = []
    @State private var locations: [CatalogLocation] = []
    @State private var catalogError: VictualError?
    @State private var isSaving = false
    @State private var confirmRemoval = false

    init(setup: MedicationSetupStore, item: SetupItem, capabilities: CapabilityGate, onSaved: (() -> Void)? = nil) {
        self.setup = setup
        self.item = item
        self.capabilities = capabilities
        self.onSaved = onSaved
        if case .mapped(let mapping) = item.status {
            _draft = State(initialValue: MappingDraft(editing: mapping))
        } else {
            _draft = State(initialValue: MappingDraft(effectiveFrom: Calendar.current.startOfDay(for: Date())))
        }
    }

    private var isMapped: Bool {
        if case .mapped = item.status { true } else { false }
    }

    var body: some View {
        Form {
            Section {
                Picker("Maps to", selection: $draft.targetKind) {
                    Text("Product").tag(MappingDraft.TargetKind.product)
                    Text("Recipe").tag(MappingDraft.TargetKind.recipe)
                }
                .pickerStyle(.segmented)
                if draft.targetKind == .product {
                    CatalogPicker(title: "Product", items: products, selection: $draft.productID)
                    unitPicker
                } else {
                    CatalogPicker(title: "Consumption recipe", items: recipes, selection: $draft.recipeID)
                }
            } header: {
                Text(item.medication.displayName)
            } footer: {
                Text(targetFooter)
            }

            Section {
                Picker("Take from", selection: $draft.locationMode) {
                    Text("This organizer").tag(MappingLocation.Mode.fixed)
                    Text("Whichever holds enough").tag(MappingLocation.Mode.single)
                    // Offered only to show a mapping made elsewhere: this app has no
                    // way to name an organizer per dose.
                    if draft.locationMode == .explicit {
                        Text("Each dose names it").tag(MappingLocation.Mode.explicit)
                    }
                }
                if draft.locationMode == .fixed {
                    Picker("Organizer", selection: $draft.locationID) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(locations) { location in
                            Text(location.name).tag(Int?.some(location.id))
                        }
                    }
                }
            } footer: {
                Text(locationFooter)
            }

            Section {
                TextField("None", text: $draft.defaultQuantityText)
                    .keyboardType(.decimalPad)
                DatePicker("Count doses from", selection: $draft.effectiveFrom)
            } header: {
                Text("Optional")
            } footer: {
                Text("A default quantity is used for a dose Health records without one; without it such a dose waits for you. Doses before the date are never read.")
            }

            Section {
                if let problem = draft.problem { Text(problem).foregroundStyle(.secondary) }
                if let reason = capabilities.reason(.consume), !capabilities.canConsume {
                    Label(reason, systemImage: "lock.fill")
                }
                if let error = setup.saveError {
                    Label(error.errorDescription ?? "The server refused the mapping.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                if let error = catalogError {
                    Label(error.errorDescription ?? "Could not load Victual's products.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save mapping") }
                }
                .disabled(draft.problem != nil || !capabilities.canConsume || isSaving)
                if isMapped {
                    Button("Remove mapping", role: .destructive) { confirmRemoval = true }
                        .disabled(!capabilities.canConsume)
                }
            }
        }
        .navigationTitle("Map medication")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCatalog() }
        .onChange(of: draft.productID) { _, _ in Task { await loadProductChoices() } }
        .onChange(of: draft.targetKind) { _, _ in Task { await loadProductChoices() } }
        .onDisappear { setup.clearSaveError() }
        .confirmationDialog("Remove this mapping?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await setup.removeMapping(for: item.id)
                    if setup.saveError == nil { dismiss() }
                }
            }
        } message: {
            Text("Doses of this medication will wait for a mapping again. Doses already booked are not changed.")
        }
    }

    @ViewBuilder
    private var unitPicker: some View {
        Picker("Unit a dose is counted in", selection: Binding(
            get: { draft.unit?.id },
            set: { id in draft.unit = units.first { $0.id == id } }
        )) {
            Text("Choose…").tag(Int?.none)
            ForEach(units) { unit in
                Text(unit.factorToStockUnit == 1 ? unit.name : "\(unit.name) (×\(unit.factorToStockUnit.formatted()))")
                    .tag(Int?.some(unit.id))
            }
        }
        .disabled(draft.productID == nil)
    }

    private var targetFooter: String {
        switch draft.targetKind {
        case .product:
            "Only units with a conversion to the product's stock unit are listed. If yours is missing, add the conversion in Victual's web UI first; this app cannot create it."
        case .recipe:
            "A recipe takes its own lines once per dose, whatever quantity Health reports."
        }
    }

    private var locationFooter: String {
        switch draft.locationMode {
        case .fixed: "Always takes from this organizer. If it holds too little, the dose waits for you; it never falls back to another."
        case .single: "Takes the dose only if exactly one organizer holds enough."
        case .explicit: "Set up elsewhere: each dose names its organizer. This app does not send one, so such doses wait for you."
        }
    }

    // MARK: Loading

    private func loadCatalog() async {
        let catalog = setup.catalogReader
        do {
            async let loadedProducts = catalog.products()
            async let loadedRecipes = catalog.recipes()
            (products, recipes) = try await (loadedProducts, loadedRecipes)
            catalogError = nil
        } catch {
            catalogError = VictualError.mapping(error)
        }
        await loadProductChoices()
    }

    /// Units and organizers for the chosen product, or every organizer for a recipe.
    private func loadProductChoices() async {
        let catalog = setup.catalogReader
        do {
            switch draft.targetKind {
            case .product:
                guard let id = draft.productID else {
                    units = []
                    locations = []
                    return
                }
                units = try await catalog.units(forProduct: id)
                draft.selectStoredUnit(from: units)
                locations = try await catalog.locations(forProduct: id)
                // The chosen unit may not exist for a newly chosen product.
                if let unit = draft.unit, !units.contains(unit) { draft.unit = nil }
            case .recipe:
                locations = try await catalog.locations(forProduct: nil)
            }
            catalogError = nil
        } catch {
            catalogError = VictualError.mapping(error)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await setup.save(draft, for: item.id) {
            onSaved?()
            dismiss()
        }
    }
}

/// A searchable list of products or recipes. Households have hundreds of products,
/// so a menu would be unusable.
struct CatalogPicker: View {
    let title: String
    let items: [CatalogItem]
    @Binding var selection: Int?

    var body: some View {
        NavigationLink {
            CatalogList(title: title, items: items, selection: $selection)
        } label: {
            LabeledContent(title, value: items.first { $0.id == selection }?.name ?? "Choose…")
        }
    }
}

private struct CatalogList: View {
    let title: String
    let items: [CatalogItem]
    @Binding var selection: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List(filtered) { item in
            Button {
                selection = item.id
                dismiss()
            } label: {
                HStack {
                    Text(item.name).foregroundStyle(.primary)
                    Spacer()
                    if item.id == selection { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .overlay {
            if items.isEmpty { ContentUnavailableView("Nothing to choose from", systemImage: "tray") }
        }
    }

    private var filtered: [CatalogItem] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
