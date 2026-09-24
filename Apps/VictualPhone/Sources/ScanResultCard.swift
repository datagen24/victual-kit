import SwiftUI
import VictualCore
import VictualStock

/// What the last scan turned out to be, and what can be done about it.
///
/// Every outcome says something. An unknown code, a retired label and a label
/// on a chore each get their own sentence rather than a generic "not found":
/// ADR-0011 asks that an unknown or retired code fail *visibly*, and a retired
/// label in particular is a discrepancy a person can act on.
struct ScanResultCard: View {
    let workspace: PhoneWorkspace

    private var scanner: ScanStore { workspace.scanner }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(scanner.code ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    scanner.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }

            content
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    @ViewBuilder
    private var content: some View {
        switch scanner.phase {
        case .idle:
            EmptyView()
        case .resolving:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking it up…").foregroundStyle(.secondary)
            }
        case .failed(let error):
            Outcome(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: error == .unauthorized ? "The API key was not accepted" : "Could not look that up",
                message: error.errorDescription ?? ""
            )
            if error.isRetryable {
                Button("Try again") { scanner.refresh() }
                    .buttonStyle(.bordered)
            }
        case .resolved(let resolution):
            resolved(resolution)
        }
    }

    @ViewBuilder
    private func resolved(_ resolution: ScanResolution) -> some View {
        switch resolution {
        case .product(let detail):
            ProductPanel(workspace: workspace, detail: detail, entry: nil)
        case .stockEntry(let entry, let detail):
            ProductPanel(workspace: workspace, detail: detail, entry: entry)
        case .location(let target):
            NavigationLink(value: ScanDestination.location(target)) {
                Outcome(
                    symbol: "archivebox.fill",
                    tint: .accentColor,
                    title: target.name,
                    message: target.path == target.name ? "A location" : target.path
                )
            }
            .buttonStyle(.plain)
            NavigationLink("What is in here", value: ScanDestination.location(target))
                .buttonStyle(.borderedProminent)
        case .otherLabel(let target):
            Outcome(
                symbol: "tag.fill",
                tint: .secondary,
                title: target.name,
                message: "This label is on a \(target.kind.displayName). This app only books stock, so there is nothing to do with it here."
            )
        case .retiredLabel(let label):
            Outcome(
                symbol: "tag.slash.fill",
                tint: .orange,
                title: "This label has been retired",
                message: retiredMessage(label)
            )
        case .unknown:
            Outcome(
                symbol: "questionmark.circle.fill",
                tint: .secondary,
                title: "Not known to this household",
                message: "No product carries this barcode, and it is not one of Victual's labels. Add it to a product's barcodes in Victual, then scan it again."
            )
        }
    }

    private func retiredMessage(_ label: RetiredLabel) -> String {
        var text = "It was on "
        if let name = label.formerName {
            text += "the \(label.kind.displayName) “\(name)”"
        } else {
            text += "a \(label.kind.displayName)"
        }
        if let retired = label.retiredAt {
            text += ", and was retired on \(retired.formatted(date: .abbreviated, time: .omitted))"
        }
        return text + ". Whatever it is on now is not what it says — take it off, or find out what happened."
    }
}

/// An icon, a title and a sentence: the shape of every non-product outcome.
private struct Outcome: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
