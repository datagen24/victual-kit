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

    @State private var amount: Double = 1
    @State private var spoiled = false
    @State private var usesDueDate = true
    @State private var dueDate = Date()
    @State private var usesPrice = false
    @State private var price: Double = 0
    @State private var locationID: Int?
    @State private var destinationID: Int?
    @State private var stockEntryID: String?
    @State private var note = ""
    @State private var allowSubstitution = false
    @State private var isCommitting = false

    private var unit: QuantityUnit? { product?.stockQuantityUnit }
    private var productName: String { product?.product.name ?? "Product \(productID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    amountField
                    if action == .consume {
                        Toggle("Thrown away rather than used", isOn: $spoiled)
                            .help("Recorded as spoiled, which is what makes a spoil rate mean anything.")
                    }
                    if action == .transfer {
                        locationPicker("From", selection: $locationID)
                        locationPicker("To", selection: $destinationID)
                    } else if action != .open {
                        locationPicker("Location", selection: $locationID, allowsAny: true)
                    }
                }

                if action == .consume || action == .open || action == .transfer {
                    Section("Specific container") {
                        entryPicker
                        if product?.hasChildProducts == true, action != .transfer {
                            Toggle("Use a sub-product if this one is out", isOn: $allowSubstitution)
                        }
                    }
                }

                if action == .purchase || action == .inventory {
                    Section {
                        Toggle("Has a due date", isOn: $usesDueDate)
                        if usesDueDate {
                            DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                        }
                        Toggle("Record a price", isOn: $usesPrice)
                        if usesPrice {
                            TextField("Price per \(unit?.name ?? "unit")", value: $price, format: .number)
                                .monospacedDigit()
                        }
                        TextField("Note", text: $note, axis: .vertical)
                    } footer: {
                        // Leaving the price off is not the same as entering 0.
                        Text("A price left off is recorded as unknown, not as free.")
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
        .onAppear(perform: prepare)
    }

    // MARK: - Fields

    @ViewBuilder
    private var amountField: some View {
        let label = action == .inventory ? "Counted amount" : "Amount"
        HStack {
            TextField(label, value: $amount, format: .number.precision(.fractionLength(0...3)))
                .monospacedDigit()
            Stepper(label, value: $amount, in: stepperRange, step: 1)
                .labelsHidden()
            if let unit {
                Text(unit.name(for: amount)).foregroundStyle(.secondary)
            }
        }
        .help(amountHelp)
    }

    /// An inventory may legitimately be set to zero — "there is none left" is a
    /// count. The other four move an amount, and moving nothing is not a thing
    /// to ask the server to do.
    private var stepperRange: ClosedRange<Double> {
        action == .inventory ? 0...100_000 : 0.001...100_000
    }

    private var amountHelp: String {
        action == .inventory
            ? "What is actually there. The server adds or removes the difference."
            : "In \(unit?.name ?? "the product's stock unit")."
    }

    @ViewBuilder
    private var entryPicker: some View {
        Picker("Container", selection: $stockEntryID) {
            Text("Whichever is due first").tag(String?.none)
            ForEach(availableEntries, id: \.id) { entry in
                Text(describe(entry)).tag(entry.stockID)
            }
        }
        .disabled(availableEntries.isEmpty)
        .onChange(of: stockEntryID) { _, new in
            // The API requires an amount of exactly 1 alongside a named entry,
            // and the wrapper refuses the combination before sending it.
            if new != nil { amount = 1 }
        }

        if stockEntryID != nil {
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
                .disabled(!isValid || isCommitting)
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

    private var isValid: Bool {
        switch action {
        case .inventory: return amount >= 0
        case .transfer:
            guard let from = locationID, let to = destinationID else { return false }
            return from != to && amount > 0
        case .consume, .purchase, .open:
            return amount > 0
        }
    }

    private func prepare() {
        switch action {
        case .inventory: amount = product?.stockAmount ?? 0
        default: amount = 1
        }
        locationID = action == .transfer ? product?.location?.id : nil
        dueDate = product?.nextDueDate ?? Date()
    }

    private func commit() {
        isCommitting = true
        let request = buildRequest()
        Task {
            await onCommit(request)
            dismiss()
        }
    }

    private func buildRequest() -> BookingRequest {
        let entry = stockEntryID.flatMap { $0.isEmpty ? nil : $0 }
        switch action {
        case .consume:
            return .consume(
                productID: productID,
                amount: amount,
                spoiled: spoiled,
                stockEntryID: entry,
                locationID: locationID,
                allowSubproductSubstitution: allowSubstitution
            )
        case .purchase:
            return .purchase(
                productID: productID,
                amount: amount,
                bestBeforeDate: usesDueDate ? dueDate : nil,
                price: usesPrice ? price : nil,
                locationID: locationID,
                shoppingLocationID: nil,
                stockLabelType: nil,
                note: note.isEmpty ? nil : note
            )
        case .open:
            return .open(
                productID: productID,
                amount: amount,
                stockEntryID: entry,
                allowSubproductSubstitution: allowSubstitution,
                measurement: nil
            )
        case .inventory:
            return .inventory(
                productID: productID,
                newAmount: amount,
                bestBeforeDate: usesDueDate ? dueDate : nil,
                locationID: locationID,
                shoppingLocationID: nil,
                price: usesPrice ? price : nil,
                stockLabelType: nil,
                note: note.isEmpty ? nil : note
            )
        case .transfer:
            return .transfer(
                productID: productID,
                amount: amount,
                fromLocationID: locationID ?? 0,
                toLocationID: destinationID ?? 0,
                stockEntryID: entry
            )
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
