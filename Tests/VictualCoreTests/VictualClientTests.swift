import Foundation
import HTTPTypes
import Testing
import VictualTestSupport

@testable import VictualCore

@Suite("VictualClient")
struct VictualClientTests {
    @Test("Sends the API key on every request")
    func authenticatesRequests() async throws {
        let transport = StubTransport(status: 200, json: systemInfoJSON)
        let client = VictualClient.stubbed(transport, apiKey: "sk-victual-123")

        _ = try await client.systemInfo()

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.request.headerFields[VictualAPIKey.headerName] == "sk-victual-123")
    }

    @Test("Addresses the API prefix under the instance URL")
    func usesAPIPrefix() async throws {
        let transport = StubTransport(status: 200, json: systemInfoJSON)
        let server = try VictualServer(userEnteredText: "https://victual.example.com")
        let client = VictualClient.stubbed(transport, server: server)

        _ = try await client.systemInfo()

        let sent = try #require(transport.recorder.requests.first)
        #expect(sent.baseURL.absoluteString == "https://victual.example.com/api")
        #expect(sent.request.path == "/system/info")
        #expect(sent.url.absoluteString == "https://victual.example.com/api/system/info")
        #expect(sent.request.method == .get)
    }

    @Test("Decodes system information")
    func decodesSystemInfo() async throws {
        let client = VictualClient.stubbed(StubTransport(status: 200, json: systemInfoJSON))

        let info = try await client.systemInfo()

        #expect(info.victualVersion == "4.2.0")
        #expect(info.releaseDate == "2025-11-02")
        #expect(info.phpVersion == "8.3.14")
        #expect(info.databaseEngine == "PostgreSQL 16.10")
    }

    @Test("Maps a rejected key to .unauthorized")
    func mapsUnauthorized() async throws {
        let transport = StubTransport(
            status: 401,
            json: #"{"error_message":"Not valid"}"#
        )
        let client = VictualClient.stubbed(transport)

        await #expect(throws: VictualError.unauthorized) {
            try await client.systemInfo()
        }
    }

    @Test("Maps an undocumented server status to .serverError")
    func mapsServerError() async throws {
        let client = VictualClient.stubbed(StubTransport(status: 503, json: "{}"))

        let error = await #expect(throws: VictualError.self) {
            try await client.systemInfo()
        }
        guard case .serverError(let statusCode, _) = try #require(error) else {
            Issue.record("expected .serverError, got \(String(describing: error))")
            return
        }
        #expect(statusCode == 503)
    }

    @Test("Maps an unreachable host to .transportFailed")
    func mapsTransportFailure() async throws {
        let client = VictualClient.stubbed(.failing())

        let error = await #expect(throws: VictualError.self) {
            try await client.systemInfo()
        }
        guard case .transportFailed = try #require(error) else {
            Issue.record("expected .transportFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("Maps a malformed body to .decodingFailed")
    func mapsDecodingFailure() async throws {
        let client = VictualClient.stubbed(
            StubTransport(status: 200, json: #"{"victual_version": "not an object"}"#)
        )

        let error = await #expect(throws: VictualError.self) {
            try await client.systemInfo()
        }
        guard case .decodingFailed = try #require(error) else {
            Issue.record("expected .decodingFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("Decodes an array response")
    func decodesCurrentStock() async throws {
        let body = """
            [{"product_id": 7, "amount": 2.5, "best_before_date": "2026-01-31"}]
            """
        let client = VictualClient.stubbed(StubTransport(status: 200, json: body))

        let stock = try await client.currentStock()

        #expect(stock.count == 1)
        #expect(stock.first?.productId == 7)
        #expect(stock.first?.amount == 2.5)
    }
}

@Suite("VictualError")
struct VictualErrorTests {
    @Test(
        "Classifies HTTP status codes",
        arguments: [
            (400, "badRequest"), (401, "unauthorized"), (403, "forbidden"),
            (404, "notFound"), (409, "badRequest"), (422, "badRequest"),
            (500, "serverError"), (503, "serverError"), (302, "unexpectedStatus"),
        ]
    )
    func classifiesStatusCodes(status: Int, expected: String) {
        let name: String
        switch VictualError.forStatus(status) {
        case .badRequest: name = "badRequest"
        case .unauthorized: name = "unauthorized"
        case .forbidden: name = "forbidden"
        case .notFound: name = "notFound"
        case .serverError: name = "serverError"
        case .unexpectedStatus: name = "unexpectedStatus"
        default: name = "other"
        }
        #expect(name == expected)
    }

    @Test("Only transport and server failures are worth retrying")
    func marksRetryableCases() {
        #expect(VictualError.transportFailed(underlying: URLError(.timedOut)).isRetryable)
        #expect(VictualError.serverError(statusCode: 500, message: nil).isRetryable)
        #expect(!VictualError.unauthorized.isRetryable)
        #expect(!VictualError.forbidden.isRetryable)
        #expect(!VictualError.badRequest(message: nil).isRetryable)
    }

    @Test("Passes an already-mapped error through unchanged")
    func doesNotDoubleWrap() {
        guard case .notFound = VictualError.mapping(VictualError.notFound) else {
            Issue.record("expected .notFound to survive mapping")
            return
        }
    }

    @Test("Every case has a user-facing description")
    func describesEveryCase() {
        let cases: [VictualError] = [
            .invalidServerURL("nope"), .unauthorized, .forbidden, .notFound,
            .badRequest(message: nil), .serverError(statusCode: 500, message: nil),
            .unexpectedStatus(statusCode: 302),
            .decodingFailed(underlying: URLError(.badServerResponse)),
            .transportFailed(underlying: URLError(.notConnectedToInternet)),
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}

@Suite("VictualAPIKey")
struct VictualAPIKeyTests {
    @Test("Never prints its value")
    func redactsItself() {
        let key = VictualAPIKey("super-secret")
        #expect(!"\(key)".contains("super-secret"))
    }

    @Test("Blank keys are not well formed", arguments: ["", " ", "\n\t "])
    func rejectsBlankKeys(raw: String) {
        #expect(!VictualAPIKey(raw).isWellFormed)
    }

    @Test("A non-blank key is well formed")
    func acceptsRealKey() {
        #expect(VictualAPIKey("abc123").isWellFormed)
    }
}
