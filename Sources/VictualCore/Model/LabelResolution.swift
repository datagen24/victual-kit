import Foundation
import OpenAPIRuntime
import VictualAPI

/// What a printed label names, as the server resolves it.
///
/// [ADR-0011](https://github.com/datagen24/victual/blob/master/docs/adr/0011-label-namespace.md)
/// makes a label's payload an opaque `vctl:<uid>` that only the database can
/// interpret. This type is the answer to "what is this label on?" — never the
/// result of reading the payload itself.
public enum LabelKind: Hashable, Sendable {
    case location
    case product
    /// One physical lot. The target id is the stock row's `id`, which is what
    /// `GET /stock/entry/{entryId}` takes — not the `stock_id` string a booking
    /// names.
    case stockEntry
    case recipe
    case chore
    case battery
    /// A kind this package does not know yet. Kept rather than dropped, so a
    /// newer server's label is reported as "resolved, but not something this
    /// app handles" instead of as unknown — which would be a false statement
    /// about the label.
    case other(String)

    init(wire: String) {
        switch wire {
        case "location": self = .location
        case "product": self = .product
        case "stock_entry": self = .stockEntry
        case "recipe": self = .recipe
        case "chore": self = .chore
        case "battery": self = .battery
        default: self = .other(wire)
        }
    }

    /// The kind in words, for a sentence like "This label is on a location".
    public var displayName: String {
        switch self {
        case .location: "location"
        case .product: "product"
        case .stockEntry: "stock entry"
        case .recipe: "recipe"
        case .chore: "chore"
        case .battery: "battery"
        case .other(let wire): wire.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// The live thing a label is attached to.
public struct LabelTarget: Hashable, Sendable {
    public var kind: LabelKind
    public var id: Int
    public var name: String
    /// For a location, its full path from the root. For every other kind the
    /// server mirrors ``name`` here.
    public var path: String

    public init(kind: LabelKind, id: Int, name: String, path: String? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.path = path ?? name
    }
}

/// A label whose target is gone.
///
/// ADR-0011 treats a retired label seen in the world as a discrepancy signal,
/// not an error to swallow: something was consumed or removed and its label was
/// not. So this carries what the label *was*, which is what a person standing
/// in front of it needs to act on.
public struct RetiredLabel: Hashable, Sendable {
    public var uid: String
    public var kind: LabelKind
    /// The target's id and name as they were when it was retired, when the
    /// server recorded them.
    public var formerID: Int?
    public var formerName: String?
    /// When the label was retired, parsed leniently; `nil` if the server's
    /// rendering could not be read, which does not make the label any less
    /// retired.
    public var retiredAt: Date?

    public init(
        uid: String,
        kind: LabelKind,
        formerID: Int? = nil,
        formerName: String? = nil,
        retiredAt: Date? = nil
    ) {
        self.uid = uid
        self.kind = kind
        self.formerID = formerID
        self.formerName = formerName
        self.retiredAt = retiredAt
    }
}

/// The server's answer to `GET /labels/resolve/{code}`.
public enum LabelResolution: Hashable, Sendable {
    /// Not a label this instance issued — or one the key may not read. The
    /// server deliberately does not distinguish the two.
    case unknown
    case resolved(uid: String, target: LabelTarget)
    case retired(RetiredLabel)
}

extension LabelResolution {
    typealias Payload = Operations.GetLabelsResolveByCode.Output.Ok.Body.JsonPayload

    /// Maps the generated union.
    ///
    /// The three cases are told apart by their required keys, which is how the
    /// generator decodes them. `status` and `kind` are `const` in the
    /// specification and arrive as untyped containers, so they are read as
    /// strings here.
    init(_ payload: Payload) {
        switch payload {
        case .case1:
            self = .unknown
        case .case2(let resolved):
            let kind = LabelKind(wire: resolved.kind.value as? String ?? "")
            self = .resolved(
                uid: resolved.uid,
                target: LabelTarget(
                    kind: kind,
                    id: resolved.target.id,
                    name: resolved.target.name,
                    path: resolved.target.path
                )
            )
        case .case3(let retired):
            self = .retired(
                RetiredLabel(
                    uid: retired.uid,
                    kind: LabelKind(wire: retired.kind.value as? String ?? ""),
                    formerID: retired.snapshot.id,
                    formerName: retired.snapshot.name,
                    retiredAt: try? VictualDates.transcoder.decode(retired.retiredAt)
                )
            )
        }
    }
}

/// What a scanned code turned out to be.
///
/// The client does not decide this by looking at the code. It asks the server
/// both questions a scan can mean — "is this one of your labels?" and "is this
/// a product's barcode?" — and reports the answer. See
/// ``VictualClient/resolveScan(_:)``.
public enum ScanResolution: Hashable, Sendable {
    /// A product, from its manufacturer barcode, a legacy `grcy:p:` code, or a
    /// product label.
    case product(ProductDetail)
    /// One specific lot, from a per-unit label. Carries the product too, since
    /// the lot alone cannot be named or measured.
    case stockEntry(StockEntry, product: ProductDetail)
    /// A storage location, from a location label.
    case location(LabelTarget)
    /// A live label on something this package has no stock screen for — a
    /// recipe, a chore, a battery, or a kind newer than this package.
    case otherLabel(LabelTarget)
    /// A label whose target has been consumed or removed.
    case retiredLabel(RetiredLabel)
    /// Neither a label nor a barcode this instance knows.
    case unknown

    /// The product this scan is about, when it is about one.
    public var product: ProductDetail? {
        switch self {
        case .product(let detail), .stockEntry(_, let detail): detail
        case .location, .otherLabel, .retiredLabel, .unknown: nil
        }
    }
}
