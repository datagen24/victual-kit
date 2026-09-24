import SwiftUI
import VictualCore
import VictualStock

/// The sheet behind all five bookings.
///
/// One sheet rather than five: they differ in which fields they show, not in
/// how they are confirmed, cancelled or reported on, and keeping that in one
/// place is what stops the transfer sheet quietly growing a different error
/// treatment from the consume sheet.
struct BookingSheet: View {
    let action: StockAction
    let product: ProductDetail?
    let productID: Int
    /// The lots the inspector already knows about, which is where they come
    /// from for every scope but a location.
    let entries: [StockEntry]
    let store: StockStore
    let onCommit: (BookingRequest) async -> Void

    @Environment(\.dismiss) private var dismiss

    /// Every field the form edits, and the rules for what they mean. Shared
    /// with the iPhone application, so the two cannot disagree about what a
    /// valid booking is.
    @State private var draft: BookingDraft
    @State private var isCommitting = false

    init(
        action: StockAction,
        product: ProductDetail?,
        productID: Int,
        entries: [StockEntry],
        store: StockStore,
        onCommit: @escaping (BookingRequest) async -> Void
    ) {
        self.action = action
        self.product = product
        self.productID = productID
        self.entries = entries
        self.store = store
        self.onCommit = onCommit
        self._draft = State(
            initialValue: BookingDraft(action: action, productID: productID, product: product))
    }

    private var unit: QuantityUnit? { product?.stockQuantityUnit }
    private var productName: String { product?.product.name ?? "Product \(productID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    amountField
                    if action == .consume {
                        Toggle("Thrown away rather than used", isOn: $draft.spoiled)
                            .help("Recorded as spoiled, which is what makes a spoil rate mean anything.")
                    }
                    if action == .transfer {
                        locationPicker("From", selection: $draft.locationID)
                        locationPicker("To", selection: $draft.destinationID)
                    } else if action != .open {
                        locationPicker("Location", selection: $draft.locationID, allowsAny: true)
                    }
                }

                if action == .consume || action == .open || action == .transfer {
                    Section("Specific container") {
                        entryPicker
                        if product?.hasChildProducts == true, action != .transfer {
                            Toggle("Use a sub-product if this one is out", isOn: $draft.allowSubstitution)
                        }
                    }
                }

                if action == .purchase || action == .inventory {
                    Section {
                        Toggle("Set a due date", isOn: $draft.usesDueDate)
                        if draft.usesDueDate {
                            DatePicker("Due", selection: $draft.dueDate, displayedComponents: .date)
                        }
                        Toggle("Record a price", isOn: $draft.usesPrice)
                        if draft.usesPrice {
                            TextField("Price per \(unit?.name ?? "unit")", value: $draft.price, format: .number)
                                .monospacedDigit()
                        }
                        TextField("Note", text: $draft.note, axis: .vertical)
                    } footer: {
                        // Leaving the price off is not the same as entering 0, and
                        // leaving the date off is not the same as "today".
                        Text(
                            "A due date left off takes the product's own shelf life. A price left off is recorded as unknown, not as free."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 440)
        .frame(minHeight: 300, maxHeight: 560)
    }

    // MARK: - Fields

    @ViewBuilder
    private var amountField: some View {
        let label = action == .inventory ? "Counted amount" : "Amount"
        HStack {
            TextField(label, value: $draft.amount, format: .number.precision(.fractionLength(0...3)))
                .monospacedDigit()
            Stepper(label, value: $draft.amount, in: draft.amountRange, step: 1)
                .labelsHidden()
            if let unit {
                Text(unit.name(for: draft.amount)).foregroundStyle(.secondary)
            }
        }
        .help(amountHelp)
    }

    private var amountHelp: String {
        action == .inventory
            ? "What is actually there. The server adds or removes the difference."
            : "In \(unit?.name ?? "the product's stock unit")."
    }

    @ViewBuilder
    private var entryPicker: some View {
        Picker("Container", selection: $draft.stockEntryID) {
            Text("Whichever is due first").tag(String?.none)
            ForEach(availableEntries, id: \.id) { entry in
                Text(describe(entry)).tag(entry.stockID)
            }
        }
        .disabled(availableEntries.isEmpty)

        if draft.stockEntryID != nil {
            Text("A named container is booked one at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func locationPicker(
        _ label: String,
        selection: Binding<Int?>,
        allowsAny: Bool = false
    ) -> some View {
        Picker(label, selection: selection) {
            if allowsAny {
                Text("Anywhere").tag(Int?.none)
            } else {
                Text("Choose…").tag(Int?.none)
            }
            ForEach(store.locations) { location in
                Text(location.path ?? location.displayName).tag(Int?.some(location.id))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(productName).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(action.title) { commit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid || isCommitting)
        }
        .padding()
    }

    // MARK: - Behaviour

    private var availableEntries: [StockEntry] {
        // The inspector's lots when it has them, and the selected location's
        // otherwise. Reading only the latter left the picker disabled in every
        // status scope, where nothing has fetched a location's entries.
        //
        // A lot with no `stock_id` is dropped: that string is what a booking
        // names, so an entry without one cannot be the subject of this picker.
        let candidates = entries.isEmpty ? store.locationEntries : entries
        return candidates.filter { $0.productID == productID && $0.stockID != nil }
    }

    private func commit() {
        isCommitting = true
        let request = draft.request
        Task {
            await onCommit(request)
            dismiss()
        }
    }

    private func describe(_ entry: StockEntry) -> String {
        var parts = [QuantityUnit.describe(entry.amount, in: unit)]
        if let due = entry.bestBeforeDate {
            parts.append("due \(due.formatted(.dateTime.year().month(.abbreviated).day()))")
        }
        if entry.isOpen { parts.append("opened") }
        return parts.joined(separator: ", ")
    }
}
