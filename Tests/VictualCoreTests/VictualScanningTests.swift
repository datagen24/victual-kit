import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualTestSupport

@testable import VictualCore

/// A transport answering the scan routes from a table of (status, body) by
/// path prefix. Anything not in the table answers 404.
private func scanTransport(_ routes: [String: (Int, String)]) -> StubTransport {
    StubTransport { request, _, _, _ in
        let path = request.path ?? ""
        // Longest prefix wins, so `/stock/products/by-barcode/` is not
        // answered by a shorter `/stock/products/` entry.
        let match = routes.keys.filter { path.hasPrefix($0) }.max { $0.count < $1.count }
        let (status, body) = match.flatMap { routes[$0] } ?? (404, #"{"error_message":"Not found"}"#)
        return (
            HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]),
            HTTPBody(body)
        )
    }
}

private let unknownLabel = #"{"status":"unknown"}"#
private let cookies = #"{"product":{"id":7,"name":"Cookies","qu_id_stock":3},"stock_amount":2}"#
private let unknownBarcode = #"{"error_message":"No product with barcode 123 found"}"#

@Suite("Scan resolution")
struct ScanResolutionTests {
    @Test("A manufacturer barcode resolves to its product")
    func barcodeResolvesToProduct() async throws {
        let transport = scanTransport([
            "/labels/resolve/": (200, unknownLabel),
            "/stock/products/by-barcode/": (200, cookies),
        ])
        let client = VictualClient.stubbed(transport)

        let result = try await client.resolveScan("4006381333931")

        guard case .product(let detail) = result else {
            Issue.record("expected a product, got \(result)")
            return
        }
        #expect(detail.id == 7)
        #expect(detail.product.name == "Cookies")
        // Both questions were asked; the client did not guess which applied.
        let paths = transport.recorder.requests.compactMap(\.request.path)
        #expect(paths.contains("/labels/resolve/4006381333931"))
        #expect(paths.contains("/stock/products/by-barcode/4006381333931"))
    }

    @Test("A code nobody recognises is unknown, not an error")
    func unrecognisedIsUnknown() async throws {
        let client = VictualClient.stubbed(
            scanTransport([
                "/labels/resolve/": (200, unknownLabel),
                "/stock/products/by-barcode/": (400, unknownBarcode),
            ]))

        let result = try await client.resolveScan("123")

        #expect(result == .unknown)
    }

    @Test("A location label resolves to the location, with its path")
    func locationLabel() async throws {
        let resolved = """
            {"status":"resolved","uid":"0123456789ABC","kind":"location",
             "target":{"id":4,"name":"Top shelf","path":"Kitchen / Pantry / Top shelf"}}
            """
        let client = VictualClient.stubbed(
            scanTransport([
                "/labels/resolve/": (200, resolved),
                "/stock/products/by-barcode/": (400, unknownBarcode),
            ]))

        let result = try await client.resolveScan("vctl:0123456789ABC")

        #expect(
            result
                == .location(
                    LabelTarget(
                        kind: .location, id: 4, name: "Top shelf",
                        path: "Kitchen / Pantry / Top shelf")))
    }

    @Test("A product label fetches the product it names")
    func productLabel() async throws {
        let resolved = """
            {"status":"resolved","uid":"0123456789ABC","kind":"product",
             "target":{"id":7,"name":"Cookies","path":"Cookies"}}
            """
        let transport = scanTransport([
            "/labels/resolve/": (200, resolved),
            "/stock/products/by-barcode/": (400, unknownBarcode),
            "/stock/products/7": (200, cookies),
        ])
        let client = VictualClient.stubbed(transport)

        let result = try await client.resolveScan("VCTL:0123456789ABC")

        #expect(result.product?.id == 7)
        #expect(
            transport.recorder.requests.contains { $0.request.path == "/stock/products/7" })
    }

    @Test("A per-unit label resolves to that lot and its product")
    func stockEntryLabel() async throws {
        let resolved = """
            {"status":"resolved","uid":"0123456789ABC","kind":"stock_entry",
             "target":{"id":77,"name":"Cookies","path":"Cookies"}}
            """
        let entry = #"{"id":77,"product_id":7,"amount":1,"stock_id":"lot-77","open":0}"#
        let client = VictualClient.stubbed(
            scanTransport([
                "/labels/resolve/": (200, resolved),
                "/stock/products/by-barcode/": (400, unknownBarcode),
                "/stock/entry/77": (200, entry),
                "/stock/products/7": (200, cookies),
            ]))

        let result = try await client.resolveScan("vctl:0123456789ABC")

        guard case .stockEntry(let lot, let product) = result else {
            Issue.record("expected a stock entry, got \(result)")
            return
        }
        #expect(lot.id == 77)
        #expect(lot.stockID == "lot-77")
        #expect(product.id == 7)
    }

    @Test("A retired label reports what it was, rather than being unknown")
    func retiredLabel() async throws {
        let retired = """
            {"status":"retired","uid":"0123456789ABC","kind":"location",
             "snapshot":{"id":4,"name":"Old freezer"},"retired_at":"2026-09-01 10:00:00.123456+00"}
            """
        let client = VictualClient.stubbed(
            scanTransport([
                "/labels/resolve/": (200, retired),
                "/stock/products/by-barcode/": (400, unknownBarcode),
            ]))

        let result = try await client.resolveScan("vctl:0123456789ABC")

        guard case .retiredLabel(let label) = result else {
            Issue.record("expected a retired label, got \(result)")
            return
        }
        #expect(label.kind == .location)
        #expect(label.formerName == "Old freezer")
        #expect(label.formerID == 4)
        // PostgreSQL's TIMESTAMPTZ rendering, which ADR-0027 names as an
        // exception for label fields: an offset, and fractional seconds.
        #expect(label.retiredAt == Date(timeIntervalSince1970: 1_788_256_800))
    }

    @Test("Timestamps read in every rendering the server documents", arguments: [
        ("2026-09-01 10:00:00+00", 1_788_256_800.0),
        ("2026-09-01 10:00:00.5+00", 1_788_256_800.0),
        ("2026-09-01 15:30:00+05:30", 1_788_256_800.0),
        ("2026-09-01T10:00:00Z", 1_788_256_800.0),
    ])
    func timestampRenderings(text: String, epoch: Double) {
        #expect(VictualDates.timestamp(text) == Date(timeIntervalSince1970: epoch))
    }

    @Test("An absent or unreadable timestamp is nil", arguments: [nil, "", "yesterday"] as [String?])
    func unreadableTimestamps(text: String?) {
        #expect(VictualDates.timestamp(text) == nil)
    }

    @Test("A label on something without a stock screen is reported, not dropped")
    func otherKindLabel() async throws {
        let resolved = """
            {"status":"resolved","uid":"0123456789ABC","kind":"houseplant",
             "target":{"id":3,"name":"Fern","path":"Fern"}}
            """
        let client = VictualClient.stubbed(
            scanTransport([
                "/labels/resolve/": (200, resolved),
                "/stock/products/by-barcode/": (400, unknownBarcode),
            ]))

        let result = try await client.resolveScan("vctl:0123456789ABC")

        #expect(
            result == .otherLabel(LabelTarget(kind: .other("houseplant"), id: 3, name: "Fern")))
    }

    @Test("An instance without label resolution still resolves barcodes")
    func olderInstanceWithoutLabels() async throws {
        // Victual 4.6.0 has no /labels/resolve and answers it 404, exactly as
        // it does /user/capabilities.
        let client = VictualClient.stubbed(
            scanTransport(["/stock/products/by-barcode/": (200, cookies)]))

        let result = try await client.resolveScan("4006381333931")

        #expect(result.product?.id == 7)
    }

    @Test("A rejected key is an error, not an unknown code")
    func unauthorizedIsAnError() async throws {
        let client = VictualClient.stubbed(
            scanTransport([
                "/labels/resolve/": (401, #"{"error_message":"no"}"#),
                "/stock/products/by-barcode/": (401, #"{"error_message":"no"}"#),
            ]))

        await #expect(throws: VictualError.unauthorized) {
            try await client.resolveScan("4006381333931")
        }
    }

    @Test("Surrounding whitespace from a hand-held scanner is dropped")
    func trimsWhitespace() async throws {
        let transport = scanTransport([
            "/labels/resolve/": (200, unknownLabel),
            "/stock/products/by-barcode/": (200, cookies),
        ])
        let client = VictualClient.stubbed(transport)

        _ = try await client.resolveScan("  4006381333931\n")

        #expect(
            transport.recorder.requests.contains {
                $0.request.path == "/stock/products/by-barcode/4006381333931"
            })
    }

    @Test("A code with reserved characters stays one path segment")
    func encodesTheCode() async throws {
        let transport = scanTransport([
            "/labels/resolve/": (200, unknownLabel),
            "/stock/products/by-barcode/": (400, unknownBarcode),
        ])
        let client = VictualClient.stubbed(transport)

        _ = try await client.resolveScan("AB/12?x")

        let barcodePath = transport.recorder.requests
            .compactMap(\.request.path)
            .first { $0.hasPrefix("/stock/products/by-barcode/") }
        #expect(barcodePath == "/stock/products/by-barcode/AB%2F12%3Fx")
    }
}

@Suite("UPC-A and EAN-13")
struct BarcodeCandidateTests {
    @Test("A 13-digit code with a leading zero also tries the 12-digit form")
    func thirteenToTwelve() {
        #expect(
            VictualClient.barcodeCandidates("0012345678905") == ["0012345678905", "012345678905"])
    }

    @Test("A 12-digit code also tries the 13-digit form")
    func twelveToThirteen() {
        #expect(
            VictualClient.barcodeCandidates("012345678905") == ["012345678905", "0012345678905"])
    }

    @Test("Everything else is asked about exactly as read")
    func othersUntouched() {
        #expect(VictualClient.barcodeCandidates("4006381333931") == ["4006381333931"])
        #expect(VictualClient.barcodeCandidates("grcy:p:7") == ["grcy:p:7"])
        #expect(VictualClient.barcodeCandidates("01234567890A") == ["01234567890A"])
    }

    @Test("The alternate form is only asked about after a miss")
    func retriesOnlyOnMiss() async throws {
        let transport = StubTransport { request, _, _, _ in
            let path = request.path ?? ""
            let hit = path == "/stock/products/by-barcode/012345678905"
            return (
                HTTPResponse(
                    status: .init(code: hit ? 200 : 400),
                    headerFields: [.contentType: "application/json"]),
                HTTPBody(hit ? cookies : unknownBarcode)
            )
        }
        let client = VictualClient.stubbed(transport)

        let detail = try await client.productDetail(barcode: "0012345678905")

        #expect(detail?.id == 7)
        #expect(
            transport.recorder.requests.compactMap(\.request.path) == [
                "/stock/products/by-barcode/0012345678905",
                "/stock/products/by-barcode/012345678905",
            ])
    }
}
