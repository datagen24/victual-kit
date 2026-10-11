import SwiftUI
import VictualCore
import VictualStock

/// One product: how much there is, when it is due, and the bookings.
///
/// Used by the scan card and by the product screen, so the phone has one
/// answer to "what can I do with this" wherever the product came from.
///
/// ## One tap for the common case
///
/// "Use one" and "Open one" book immediately. That is the whole point of
/// scanning a thing in your hand; a form would make the camera slower than the
/// web UI. The undo bar is the safety net. Everything that needs an amount, a
/// date or a place opens the form.
///
/// ## Disabled, and saying why
///
/// As on the Mac, a booking the key may not make is disabled rather than
/// hidden. A phone has no tooltips, so the reason is written underneath.
struct ProductPanel: View {
    let workspace: PhoneWorkspace
    let detail: ProductDetail
    /// Set when a per-unit label named one lot: bookings then address that lot.
    let entry: StockEntry?
    /// Whether the name links to the product screen. Off on that screen.
    var linksToDetail = true

    @Environment(\.dynamicTypeSize) private var typeSize

    /// At the accessibility sizes a label column and three buttons no longer
    /// fit side by side; the panel clipped at the left edge. Stack them instead.
    private var stacked: Bool { typeSize.isAccessibilitySize }

    private var gate: CapabilityGate { workspace.capabilities }
    private var unit: QuantityUnit? { detail.stockQuantityUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            facts
            actions
            if let reason = obstacle {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - What it is

    @ViewBuilder
    private var header: some View {
        if linksToDetail {
            NavigationLink(value: ScanDestination.product(detail.id)) {
                HStack {
                    title
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            title
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(detail.product.name)
                .font(.title3.weight(.semibold))
            if entry != nil {
                Label("One specific container, from its label", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let entry {
                fact("This one", QuantityUnit.describe(entry.amount, in: unit) + (entry.isOpen ? ", opened" : ""))
                if let due = entry.bestBeforeDate { dueFact(due) }
                if let location = entry.locationID.flatMap(workspace.stock.location) {
                    fact("Where", location.path ?? location.displayName)
                }
            } else {
                if detail.hasChildStock {
                    fact("This product", stockText(detail.stockAmount, opened: detail.stockAmountOpened), stackedLabel: true)
                    fact(
                        "Including child products",
                        stockText(detail.displayedStockAmount, opened: detail.displayedStockAmountOpened),
                        stackedLabel: true
                    )
                    Text("Child products' stock counts in the total. It is used from here only when sub-product substitution is allowed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    fact("In stock", stockText(detail.displayedStockAmount, opened: detail.displayedStockAmountOpened))
                }
                if let due = detail.nextDueDate { dueFact(due) }
                if let location = detail.location {
                    fact("Where", location.path ?? location.displayName)
                }
            }
        }
        .font(.subheadline)
    }

    private func stockText(_ amount: Double, opened: Double) -> String {
        var text = QuantityUnit.describe(amount, in: unit)
        if opened > 0 {
            text += ", \(QuantityUnit.describe(opened, in: unit)) opened"
        }
        return text
    }

    private func fact(_ label: String, _ value: String, stackedLabel: Bool = false) -> some View {
        factRow(label, stackedLabel: stackedLabel) { Text(value).monospacedDigit() }
    }

    private func dueFact(_ due: Date) -> some View {
        factRow("Due") {
            Text(due, format: .dateTime.year().month(.abbreviated).day())
                .foregroundStyle(due < Calendar.current.startOfDay(for: .now) ? .red : .primary)
                .monospacedDigit()
        }
    }

    /// A label and its value: side by side, or one above the other when large
    /// text leaves no room for a label column.
    private func factRow<Value: View>(
        _ label: String,
        stackedLabel: Bool = false,
        @ViewBuilder value: () -> Value
    ) -> some View {
        // A long label ("Including child products") has no room in the label column.
        let layout = stacked || stackedLabel
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            // Stacked, the label drops to a caption so the value carries the row.
            Text(label)
                .font(stacked ? .footnote : nil)
                .foregroundStyle(.secondary)
                .frame(width: stacked || stackedLabel ? nil : 72, alignment: .leading)
            value()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, stacked ? 4 : 0)
        .accessibilityElement(children: .combine)
    }

    // MARK: - What can be done

    private var actions: some View {
        // Titles alone, on one line: an icon beside "Open one" is what truncated
        // it. At accessibility sizes the buttons stack full width instead.
        buttons(vertical: stacked)
            .controlSize(.large)
            .disabled(workspace.bookings.isWorking)
    }

    private func buttons(vertical: Bool) -> some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button {
                Task { await workspace.bookOne(.consume, of: detail, entry: entry) }
            } label: {
                Text("Use one")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canBookOne(.consume))

            Button {
                Task { await workspace.bookOne(.open, of: detail, entry: entry) }
            } label: {
                Text("Open one")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canBookOne(.open) || entry?.isOpen == true)

            Menu {
                ForEach(StockAction.allCases) { action in
                    Button(menuTitle(action) + (gate.shortReason(action).map { " (\($0))" } ?? "")) {
                        workspace.beginBooking(action, product: detail, entry: entry)
                    }
                    .disabled(!gate.canWrite(action))
                }
            } label: {
                if vertical {
                    Text("More").lineLimit(1).frame(maxWidth: .infinity)
                } else {
                    Label("More", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 32)
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("More bookings")
        }
    }

    private func menuTitle(_ action: StockAction) -> String {
        switch action {
        case .consume: "Use some…"
        case .purchase: "Add to stock…"
        case .open: "Mark some opened…"
        case .inventory: "Correct the count…"
        case .transfer: "Move…"
        }
    }

    /// Whether a one-tap booking can work at all.
    ///
    /// Nothing in stock means there is nothing to use — unless this is a parent
    /// product, whose children the server may substitute.
    private func canBookOne(_ action: StockAction) -> Bool {
        guard gate.canWrite(action) else { return false }
        if entry != nil { return true }
        return detail.stockAmount > 0 || detail.hasChildProducts
    }

    /// The first reason a booking is unavailable, in a sentence.
    ///
    /// A key that may use and open but not add, count or move still gets its
    /// greyed More rows explained, since a menu row has no room for a tooltip.
    private var obstacle: String? {
        if let reason = gate.reason(.consume) ?? gate.reason(.open) { return reason }
        let blocked = StockAction.allCases.filter { !gate.canWrite($0) }
        if !blocked.isEmpty {
            let names = blocked.map { "\(menuTitle($0).replacingOccurrences(of: "…", with: ""))" }
            return "\(names.joined(separator: ", ")) are greyed out in More: this account lacks the permission for each."
        }
        if entry == nil, detail.stockAmount <= 0, !detail.hasChildProducts {
            return "None in stock. Use More to add some."
        }
        return nil
    }
}
