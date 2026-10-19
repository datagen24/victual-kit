import SwiftUI
import VictualCore
import VictualStock

/// The form behind every booking that needs more than "one".
///
/// The phone's counterpart to the macOS `BookingSheet`, over the same
/// `BookingDraft`: the two lay fields out differently and agree, by
/// construction, on what they mean.
struct BookingForm: View {
    let workspace: PhoneWorkspace

    @State private var draft: BookingDraft
    @State private var isCommitting = false
    @Environment(\.dismiss) private var dismiss

    private let product: ProductDetail?

    init(presentation: BookingPresentation, workspace: PhoneWorkspace) {
        self.workspace = workspace
        self.product = presentation.product
        self._draft = State(initialValue: presentation.draft)
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var action: StockAction { draft.action }
    private var unit: QuantityUnit? { product?.stockQuantityUnit }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    amountField
                    if action == .consume {
                        Toggle("Thrown away rather than used", isOn: $draft.spoiled)
                    }
                    if action == .transfer {
                        locationPicker("From", selection: $draft.locationID, allowsAny: false)
                        locationPicker("To", selection: $draft.destinationID, allowsAny: false)
                    } else if action != .open {
                        locationPicker(
                            action == .purchase ? "Put in" : "Location",
                            selection: $draft.locationID,
                            allowsAny: true
                        )
                    }
                } footer: {
                    if let problem = draft.problem {
                        Text(problem).foregroundStyle(.red)
                    } else if action == .inventory {
                        Text("What is actually there. The server adds or removes the difference.")
                    } else if draft.stockEntryID != nil {
                        Text("One specific container, booked one at a time.")
                    }
                }

                if product?.hasChildProducts == true, action == .consume || action == .open {
                    Section {
                        Toggle("Use a sub-product if this one is out", isOn: $draft.allowSubstitution)
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
                                .keyboardType(.decimalPad)
                                .monospacedDigit()
                        }
                        TextField("Note", text: $draft.note, axis: .vertical)
                    } footer: {
                        Text(
                            "A due date left off takes the product's own shelf life. A price left off is recorded as unknown, not as free."
                        )
                    }
                }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action.title) { commit() }
                        .disabled(!draft.isValid || isCommitting)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(action.title).font(.headline)
                        if let name = product?.product.name {
                            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isCommitting)
        // Shown here rather than by the tabs: a presenter with this sheet up
        // cannot show an alert of its own.
        // Suppressed while committing: a booking that may have landed closes
        // the form with isCommitting still set, and its alert, with any retry,
        // belongs to the root view once the form has gone.
        .bookingErrorAlert(workspace: workspace, isSuppressed: isCommitting)
    }

    @ViewBuilder
    private var amountField: some View {
        let label = action == .inventory ? "Counted" : "Amount"
        // At accessibility sizes the label, field, unit and stepper cannot share
        // a line: the unit broke mid-word. They stack, each on its own line.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
        return layout {
            Text(label)
            if !typeSize.isAccessibilitySize { Spacer() }
            HStack {
                TextField("Amount", value: $draft.amount, format: .number.precision(.fractionLength(0...3)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                    .monospacedDigit()
                    .disabled(draft.stockEntryID != nil)
                if let unit {
                    Text(unit.name(for: draft.amount))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Stepper("Amount", value: $draft.amount, in: draft.amountRange, step: 1)
                    .labelsHidden()
                    .disabled(draft.stockEntryID != nil)
            }
        }
    }

    @ViewBuilder
    private func locationPicker(_ label: String, selection: Binding<Int?>, allowsAny: Bool) -> some View {
        let picker = Picker(label, selection: selection) {
            Text(allowsAny ? (action == .purchase ? "Product's default" : "Anywhere") : "Choose…")
                .tag(Int?.none)
            ForEach(workspace.stock.locations) { location in
                Text(location.path ?? location.displayName).tag(Int?.some(location.id))
            }
        }
        // A menu picker truncates its value ("Prod…efault") at large text; a
        // navigation-style row wraps it.
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.navigationLink)
        } else {
            picker.pickerStyle(.menu)
        }
    }

    /// Sends the booking, closing the form only if it worked. A refusal keeps
    /// the draft on screen so it can be corrected rather than retyped.
    private func commit() {
        isCommitting = true
        let request = draft.request
        Task {
            if await workspace.perform(request) {
                dismiss()
            } else if workspace.bookings.error?.leavesBookingUnsettled == true {
                // It may have gone through, or may yet. Close the form so it
                // cannot be edited and sent again under a new key; the alert
                // explains, offers the safe retry where there is one, and the
                // stock was refreshed.
                dismiss()
            } else {
                isCommitting = false
            }
        }
    }
}

private extension VictualError {
    /// Whether the booking that failed may still have been recorded, or its key
    /// is spent: either way the draft must not go out again as it stands.
    var leavesBookingUnsettled: Bool {
        switch self {
        case .outcomeUnknown, .idempotencyInProgress, .idempotencyConflict: true
        default: false
        }
    }
}
