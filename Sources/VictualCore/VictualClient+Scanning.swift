import Foundation
import VictualAPI

/// Turning a scanned code into something a stock screen can act on.
///
/// ## The client never reads the payload
///
/// [ADR-0011](https://github.com/datagen24/victual/blob/master/docs/adr/0011-label-namespace.md)
/// resolves label and barcode payloads **server-side**: a client never parses
/// `vctl:` or `grcy:` itself, and an unknown or retired code fails visibly
/// rather than resolving to the wrong thing. So nothing here looks at a code to
/// decide what it is. ``resolveScan(_:)`` asks the server both questions a scan
/// can mean, and reports whichever it answered.
///
/// The one exception is deliberately not about labels: see
/// ``productDetail(barcode:)`` for the UPC-A / EAN-13 retry, which is about how
/// phones read retail barcodes rather than about any Victual namespace.
extension VictualClient {
    /// Resolves anything a camera can read off a physical object.
    ///
    /// Two requests, sent together so a scan costs one round trip:
    ///
    /// - `GET /labels/resolve/{code}` — Victual's own labels (`vctl:`), for a
    ///   location, a product, a single lot, and the kinds this app has no screen
    ///   for.
    /// - `GET /stock/products/by-barcode/{code}` — a manufacturer barcode, or a
    ///   legacy `grcy:p:` code, which the server still reads (ADR-0011 item 3).
    ///
    /// A label answer wins over a barcode answer, following ADR-0011 item 2's
    /// order: the new namespace first, then Grocycode, then product barcodes.
    /// In practice they never both match — a label uid is 64 random bits — but
    /// the order is the server's, so it is stated rather than left to chance.
    ///
    /// An instance too old to have `/labels/resolve` answers it `404`. That is
    /// read as "no label", not as a failure, so product barcodes keep working
    /// against it — the same degradation ``capabilities()`` gets.
    ///
    /// - Returns: ``ScanResolution/unknown`` when neither side recognises the
    ///   code. That is an answer, not an error: a barcode this household has
    ///   never linked to a product is the ordinary case for a new package.
    public func resolveScan(_ code: String) async throws(VictualError) -> ScanResolution {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return .unknown }

        // `async let` erases the typed throw; both are rejoined through
        // `mapping`, which passes a `VictualError` straight through.
        async let labelTask = labelOrNothing(code)
        async let productTask = productDetail(barcode: code)
        let label: LabelResolution
        let product: ProductDetail?
        do {
            label = try await labelTask
            product = try await productTask
        } catch {
            throw VictualError.mapping(error)
        }

        switch label {
        case .resolved(_, let target):
            return try await scanResolution(for: target)
        case .retired(let retired):
            return .retiredLabel(retired)
        case .unknown:
            return product.map(ScanResolution.product) ?? .unknown
        }
    }

    /// Asks the server whether `code` is one of its labels.
    ///
    /// Accepts a bare uid or a `vctl:` payload; the server canonicalizes case
    /// and Crockford's look-alike letters. A label the key's owner may not read
    /// is reported as ``LabelResolution/unknown``, indistinguishably from one
    /// that does not exist — the server's choice, so as not to confirm that a
    /// label exists to someone who cannot see what it is on.
    public func resolveLabel(_ code: String) async throws(VictualError) -> LabelResolution {
        try await perform {
            try await underlying.getLabelsResolveByCode(.init(path: .init(code: code)))
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return LabelResolution(try response.body.json)
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// The product a barcode belongs to, or `nil` when no product carries it.
    ///
    /// The server answers an unknown barcode with `400` — as it does a
    /// Grocycode naming something other than a product — so that status is
    /// the ordinary "not ours" answer here, not a failure.
    ///
    /// ## UPC-A and EAN-13
    ///
    /// A UPC-A barcode is an EAN-13 with a leading zero, and readers disagree
    /// about which to report: Apple's scanners give the 13-digit form, while a
    /// barcode typed in, or read by the web UI's scanner, is often the 12-digit
    /// one. The server matches the stored string exactly. So when a 13-digit
    /// code with a leading zero misses, the 12-digit form is tried, and the
    /// reverse. The retry only happens on a miss and only for all-digit codes of
    /// exactly those lengths; nothing else is rewritten.
    public func productDetail(barcode: String) async throws(VictualError) -> ProductDetail? {
        for candidate in Self.barcodeCandidates(barcode) {
            if let detail = try await productDetailIfKnown(barcode: candidate) {
                return detail
            }
        }
        return nil
    }

    /// One stock lot, by its row id — which is what a per-unit label names.
    public func stockEntry(id: Int) async throws(VictualError) -> StockEntry {
        try await perform {
            try await underlying.getStockEntryByEntryId(.init(path: .init(entryId: id)))
        } unwrap: { output in
            switch output {
            case .ok(let response):
                guard let entry = StockEntry(try response.body.json) else {
                    throw VictualError.notFound
                }
                return entry
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    // MARK: - Internals

    /// The spellings of `barcode` worth asking about, in order.
    static func barcodeCandidates(_ barcode: String) -> [String] {
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.allSatisfy(\.isASCIIDigit) else { return [code] }
        switch code.count {
        case 13 where code.hasPrefix("0"): return [code, String(code.dropFirst())]
        case 12: return [code, "0" + code]
        default: return [code]
        }
    }

    private func productDetailIfKnown(barcode: String) async throws(VictualError) -> ProductDetail? {
        try await perform {
            try await underlying.getStockProductsByBarcodeByBarcode(
                .init(path: .init(barcode: barcode))
            )
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return ProductDetail(try response.body.json)
            case .badRequest:
                return nil
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// ``resolveLabel(_:)``, with an instance that predates labels reading as
    /// "not a label".
    private func labelOrNothing(_ code: String) async throws(VictualError) -> LabelResolution {
        do {
            return try await resolveLabel(code)
        } catch .notFound {
            return .unknown
        }
    }

    /// Fetches what a live label's target needs to be shown.
    private func scanResolution(for target: LabelTarget) async throws(VictualError) -> ScanResolution {
        switch target.kind {
        case .location:
            return .location(target)
        case .product:
            return .product(try await productDetail(id: target.id))
        case .stockEntry:
            let entry = try await stockEntry(id: target.id)
            guard let productID = entry.productID else { throw VictualError.notFound }
            return .stockEntry(entry, product: try await productDetail(id: productID))
        case .recipe, .chore, .battery, .other:
            return .otherLabel(target)
        }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
