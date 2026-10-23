import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualTestSupport

@testable import VictualCore

/// An instance behind Cloudflare Access and its firewall.
///
/// The responses here are the ones the operator observed against production
/// (VictualKit Access Brief, revision 2): none is JSON, and none came from
/// Victual.
@Suite("Edge access")
struct EdgeAccessTests {
    private let token = VictualEdgeCredential(clientID: "abc123.access", clientSecret: "cfast_s3cret")

    /// A transport answering every request with `status` and `headers`, and
    /// an HTML body as Cloudflare sends.
    private func cloudflare(_ status: Int, _ headers: HTTPFields) -> StubTransport {
        StubTransport { _, _, _, _ in
            var fields = headers
            if fields[.contentType] == nil { fields[.contentType] = "text/html; charset=UTF-8" }
            return (HTTPResponse(status: .init(code: status), headerFields: fields), HTTPBody("<html></html>"))
        }
    }

    private func client(_ transport: StubTransport, edge: VictualEdgeCredential? = nil) -> VictualClient {
        VictualClient(
            server: VictualServer(instanceURL: URL(string: "https://victual.test")!),
            apiKey: "test-key",
            edgeCredential: edge,
            transport: transport
        )
    }

    // MARK: - Credential

    @Test("Sends the service token beside the API key")
    func sendsToken() async throws {
        let transport = StubTransport(status: 200, json: systemInfoJSON)

        _ = try await client(transport, edge: token).systemInfo()

        let fields = try #require(transport.recorder.requests.first).request.headerFields
        #expect(fields[VictualEdgeCredential.clientIDHeaderName] == "abc123.access")
        #expect(fields[VictualEdgeCredential.clientSecretHeaderName] == "cfast_s3cret")
        #expect(fields[VictualAPIKey.headerName] == "test-key")
    }

    @Test("Sends no token headers for an instance without one")
    func noTokenNoHeaders() async throws {
        let transport = StubTransport(status: 200, json: systemInfoJSON)

        _ = try await client(transport).systemInfo()

        let fields = try #require(transport.recorder.requests.first).request.headerFields
        #expect(fields[VictualEdgeCredential.clientIDHeaderName] == nil)
        #expect(fields[VictualEdgeCredential.clientSecretHeaderName] == nil)
    }

    @Test("Sends the token on the raw path too")
    func rawPathCarriesToken() async throws {
        let transport = StubTransport(status: 200, json: "{}")

        _ = try await client(transport, edge: token).send(.post, path: "/x", body: Data("{}".utf8), operationID: "x")

        let fields = try #require(transport.recorder.requests.first).request.headerFields
        #expect(fields[VictualEdgeCredential.clientSecretHeaderName] == "cfast_s3cret")
    }

    @Test("Never prints the secret")
    func redacted() {
        #expect(!String(describing: token).contains("cfast_"))
        #expect(!String(reflecting: token).contains("cfast_"))
    }

    @Test("Reads a form: both fields, or neither", arguments: [
        ("id.access", " cfast_x\n", true, true),
        ("", "", true, false),
        ("id.access", "", false, false),
        ("  ", "cfast_x", false, false),
    ])
    func formEntry(id: String, secret: String, complete: Bool, credential: Bool) {
        #expect(VictualEdgeCredential.isComplete(clientID: id, clientSecret: secret) == complete)
        let entered = VictualEdgeCredential.entered(clientID: id, clientSecret: secret)
        #expect((entered != nil) == credential)
        if let entered { #expect(entered.clientSecret == "cfast_x") }
    }

    // MARK: - Classification

    @Test("The Access login redirect is access required")
    func accessRedirect() async throws {
        let transport = cloudflare(302, [
            .location: "https://scpeterson.cloudflareaccess.com/cdn-cgi/access/login/victual.test?kid=1",
            .server: "cloudflare",
        ])

        await #expect(throws: VictualError.edgeAccessRequired) {
            try await client(transport, edge: token).systemInfo()
        }
    }

    @Test("A firewall 403 is blocked, not a permission error, and keeps the Ray ID")
    func firewallBlock() async throws {
        let transport = cloudflare(403, [.server: "cloudflare", .init("cf-ray")!: "8f1a2b3c4d5e6f70-IAD"])

        let error = await #expect(throws: VictualError.self) {
            try await client(transport, edge: token).systemInfo()
        }
        #expect(error == .edgeBlocked(rayID: "8f1a2b3c4d5e6f70-IAD"))
        #expect(error?.errorDescription?.contains("8f1a2b3c4d5e6f70-IAD") == true)
    }

    @Test("A bot challenge is challenged")
    func challenge() async throws {
        let transport = cloudflare(403, [.server: "cloudflare", .init("cf-mitigated")!: "challenge"])

        await #expect(throws: VictualError.edgeChallenged(rayID: nil)) {
            try await client(transport, edge: token).systemInfo()
        }
    }

    @Test("A tunnel that is down is unreachable, nothing sent")
    func tunnelDown() async throws {
        await #expect(throws: VictualError.edgeUnreachable(rayID: nil, requestSent: false)) {
            try await client(cloudflare(530, [.server: "cloudflare"])).systemInfo()
        }
    }

    @Test("An origin error through Cloudflare is unreachable, outcome unknown", arguments: [502, 520, 524])
    func originError(status: Int) async throws {
        await #expect(throws: VictualError.edgeUnreachable(rayID: nil, requestSent: nil)) {
            try await client(cloudflare(status, [.server: "cloudflare"])).systemInfo()
        }
    }

    @Test("Victual's own JSON errors through Cloudflare are left alone")
    func victualErrorsPassThrough() async throws {
        let transport = StubTransport { _, _, _, _ in
            (
                HTTPResponse(status: .forbidden, headerFields: [.contentType: "application/json", .server: "cloudflare"]),
                HTTPBody(#"{"error_message":"No"}"#)
            )
        }

        await #expect(throws: VictualError.forbidden) {
            try await client(transport, edge: token).systemInfo()
        }
    }

    @Test("A 403 that did not come from Cloudflare is left alone")
    func otherProxies() {
        let response = HTTPResponse(status: .forbidden, headerFields: [.contentType: "text/html", .server: "nginx"])
        #expect(EdgeResponseMiddleware.edgeFailure(for: response) == nil)
    }

    // MARK: - Writes

    @Test("An edge refusal of a write means it was not done")
    func refusedWritesAreNotUnknown() {
        for refusal: VictualError in [
            .edgeAccessRequired, .edgeBlocked(rayID: nil), .edgeChallenged(rayID: nil),
            .edgeUnreachable(rayID: nil, requestSent: false),
        ] {
            #expect(VictualError.writeFailure(refusal) == refusal)
        }
    }

    @Test("A write that reached the origin and failed is outcome unknown")
    func originFailureOnWrite() async throws {
        let transport = cloudflare(524, [.server: "cloudflare", .init("cf-ray")!: "abc-IAD"])

        let error = await #expect(throws: VictualError.self) {
            try await client(transport, edge: token).send(.post, path: "/x", body: Data("{}".utf8), operationID: "x")
        }
        let failure = VictualError.writeFailure(try #require(error))
        #expect(failure.isOutcomeUnknown)
        #expect(failure.rayID == "abc-IAD")
    }

    @Test("Retrying: unreachable may succeed, a refusal will not")
    func retryable() {
        #expect(VictualError.edgeUnreachable(rayID: nil, requestSent: false).isRetryable)
        #expect(!VictualError.edgeAccessRequired.isRetryable)
        #expect(!VictualError.edgeBlocked(rayID: nil).isRetryable)
        #expect(!VictualError.edgeChallenged(rayID: nil).isRetryable)
    }
}

// MARK: - Through URLSession

/// The default transport against a `URLProtocol` stub, so that redirects go
/// through `URLSession` itself rather than a stub transport, which cannot
/// exercise them.
@Suite("Edge access through URLSession", .serialized)
struct EdgeAccessSessionTests {
    private let server = VictualServer(instanceURL: URL(string: "https://victual.edge.test")!)

    private func client(edge: VictualEdgeCredential? = nil) -> VictualClient {
        VictualClient(
            server: server,
            apiKey: "test-key",
            edgeCredential: edge,
            transport: TimeoutRoutingTransport(protocolClasses: [CloudflareStub.self])
        )
    }

    @Test("Stops at the Access redirect instead of loading the login page")
    func stopsAtAccessRedirect() async throws {
        CloudflareStub.reset(mode: .accessRedirect)

        await #expect(throws: VictualError.edgeAccessRequired) {
            try await client().systemInfo()
        }
        #expect(CloudflareStub.hosts == ["victual.edge.test"])
    }

    @Test("Still follows an ordinary redirect")
    func followsOtherRedirects() async throws {
        CloudflareStub.reset(mode: .ordinaryRedirect)

        let info = try await client().systemInfo()

        #expect(info.victualVersion == "4.2.0")
        #expect(CloudflareStub.hosts == ["victual.edge.test", "victual.edge.test"])
    }

    @Test("A session without the guard would load the login page")
    func redirectControl() async throws {
        // Without this, the stop test above would pass against a stub whose
        // redirect never reaches the session's delegate at all.
        CloudflareStub.reset(mode: .accessRedirect)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudflareStub.self]

        _ = try await URLSession(configuration: configuration)
            .data(from: URL(string: "https://victual.edge.test/api/system/info")!)

        #expect(CloudflareStub.hosts == ["victual.edge.test", "scpeterson.cloudflareaccess.com"])
    }

    @Test("Keeps no cookies, so a revoked token stops working on the next request")
    func keepsNoCookies() {
        // Checked on the configuration: a URLProtocol stub never sees cookies,
        // with or without storage, so it cannot show this.
        let configuration = TimeoutRoutingTransport.session(timeout: 10).configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
    }
}

/// Answers for an instance behind Cloudflare, recording what reached it.
final class CloudflareStub: URLProtocol, @unchecked Sendable {
    enum Mode { case accessRedirect, ordinaryRedirect }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = Mode.accessRedirect
    nonisolated(unsafe) private static var seenHosts: [String] = []

    static func reset(mode: Mode) {
        lock.withLock {
            self.mode = mode
            seenHosts = []
        }
    }

    static var hosts: [String] { lock.withLock { seenHosts } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let mode = Self.lock.withLock {
            Self.seenHosts.append(url.host ?? "")
            return Self.mode
        }

        switch mode {
        case .accessRedirect where url.host == "victual.edge.test":
            redirect(to: "https://scpeterson.cloudflareaccess.com/cdn-cgi/access/login/victual.edge.test")
        case .ordinaryRedirect where url.path == "/api/system/info":
            redirect(to: "https://victual.edge.test/api/system/info-moved")
        case .accessRedirect:
            respond(200, contentType: "text/html", body: "<html>Sign in</html>")
        case .ordinaryRedirect:
            respond(200, contentType: "application/json", body: systemInfoJSON)
        }
    }

    override func stopLoading() {}

    private func redirect(to location: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": location, "Server": "cloudflare", "Content-Type": "text/html"])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
        // Reached only when the redirect is refused: the 302 is then the answer.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond(_ status: Int, contentType: String, body: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
