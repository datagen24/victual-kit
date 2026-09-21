import SwiftUI
import VictualCore
import VictualStock

/// The detail column: one product, and the lots it is made of.
struct ProductInspector: View {
    @Bindable var store: ProductDetailStore
    let showsPrices: Bool
    let locationName: (Int) -> String?

    var body: some View {
        Group {
            if let detail = store.detail {
                loaded(detail)
            } else if store.state.isLoading {
                ProgressView().controlSize(.large)
            } else if let error = store.state.error {
                ContentUnavailableView(
                    "Could not read this product",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.errorDescription ?? "")
                )
            } else {
                ContentUnavailableView(
                    "No product selected",
                    systemImage: "shippingbox",
                    description: Text("Pick a row to see what it is made of.")
                )
            }
        }
        .frame(minWidth: 280)
    }

    private func loaded(_ detail: ProductDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(detail)
                Divider()
                summary(detail)
                Divider()
                entries(detail)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ detail: ProductDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.product.name)
                .font(.title2.weight(.semibold))
            if let details = detail.product.details, !details.isEmpty {
                Text(details).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ detail: ProductDetail) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            row("In stock", QuantityUnit.describe(detail.stockAmount, in: detail.stockQuantityUnit))
            if detail.stockAmountOpened > 0 {
                row(
                    "Opened",
                    QuantityUnit.describe(detail.stockAmountOpened, in: detail.stockQuantityUnit)
                )
            }
            if let measured = detail.stockAmountMeasured {
                row(
                    "Measured",
                    QuantityUnit.describe(measured, in: detail.stockQuantityUnit),
                    help: "Weighed contents of opened containers, kept apart from the count."
                )
            }
            if detail.product.minimumStockAmount > 0 {
                row(
                    "Minimum",
                    QuantityUnit.describe(
                        detail.product.minimumStockAmount, in: detail.stockQuantityUnit)
                )
            }
            row("Next due", detail.nextDueDate.map(Self.format) ?? "—")
            row("Location", detail.location.map { $0.path ?? $0.displayName } ?? "—")
            if let shelfLife = detail.averageShelfLifeDays, shelfLife >= 0 {
                row("Average shelf life", "\(Int(shelfLife.rounded())) days")
            }

            // Every price disappears together when the key may not see them, so
            // the whole block is conditional rather than four em dashes.
            if showsPrices {
                row("Last price", Self.money(detail.lastPrice))
                row("Average price", Self.money(detail.averagePrice))
                row("Stock value", Self.money(detail.stockValue))
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .help(help ?? "")
    }

    private func entries(_ detail: ProductDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stock entries").font(.headline)
                Spacer()
                if detail.hasChildProducts {
                    Toggle("Include sub-products", isOn: $store.includeSubProducts)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .onChange(of: store.includeSubProducts) { _, _ in store.refresh() }
                }
            }

            if store.orderedEntries.isEmpty {
                Text("Nothing in stock.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(store.orderedEntries) { entry in
                    EntryRow(
                        entry: entry,
                        unit: detail.stockQuantityUnit,
                        showsPrices: showsPrices,
                        locationName: entry.locationID.flatMap(locationName)
                    )
                }
            }
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    /// A price, or an em dash. Never a zero: a missing price is not free.
    private static func money(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—"
    }
}

/// One lot, with what distinguishes it from the others.
private struct EntryRow: View {
    let entry: StockEntry
    let unit: QuantityUnit?
    let showsPrices: Bool
    let locationName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(QuantityUnit.describe(entry.amount, in: unit))
                        .monospacedDigit()
                    if entry.isOpen {
                        Text("opened")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    if let due = entry.bestBeforeDate {
                        Label(
                            due.formatted(.dateTime.year().month(.abbreviated).day()),
                            systemImage: "calendar"
                        )
                        .foregroundStyle(due < Date() ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    if let locationName {
                        Label(locationName, systemImage: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let measured = entry.openedAmount {
                    Text("\(measured.formatted(.number.precision(.fractionLength(0...2)))) left when last weighed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsPrices {
                // Within a shown column, an em dash means no price was recorded
                // — which is different from not being allowed to see one.
                Text(entry.price.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(entry.price == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider() }
    }
}
