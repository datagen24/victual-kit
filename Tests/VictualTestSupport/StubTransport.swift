import Foundation
import HTTPTypes
import OpenAPIRuntime
import VictualCore

/// A `ClientTransport` that answers from a closure instead of the network.
///
/// Lets the tests drive ``VictualClient`` and ``VictualSession`` through real
/// request encoding and response decoding without a server.
public struct StubTransport: ClientTransport {
    /// One request as the transport received it.
    ///
    /// The generated client splits a call into a `baseURL` and a server-relative
    /// path; only their combination is what actually goes on the wire, so
    /// ``url`` is usually what a test wants to assert on.
    public struct Recorded: Sendable {
        public let request: HTTPRequest
        public let baseURL: URL

        /// The absolute URL the transport would request.
        ///
        /// Mirrors `URLSessionTransport`, which concatenates the operation path
        /// onto the base URL's path rather than resolving it as a relative
        /// reference -- a leading-slash path would otherwise discard the
        /// server's own path prefix.
        public var url: URL {
            guard
                var base = URLComponents(string: baseURL.absoluteString),
                let relative = URLComponents(string: request.path ?? "")
            else { return baseURL }
            base.percentEncodedPath += relative.percentEncodedPath
            base.percentEncodedQuery = relative.percentEncodedQuery
            return base.url ?? baseURL
        }
    }

    /// Every request the transport has been handed, in order.
    public final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Recorded] = []

        public init() {}

        public var requests: [Recorded] {
            lock.withLock { storage }
        }

        func record(_ recorded: Recorded) {
            lock.withLock { storage.append(recorded) }
        }
    }

    public let recorder = Recorder()
    private let respond:
        @Sendable (HTTPRequest, HTTPBody?, URL, String) async throws -> (HTTPResponse, HTTPBody?)

    public init(
        respond: @escaping @Sendable (HTTPRequest, HTTPBody?, URL, String) async throws -> (
            HTTPResponse, HTTPBody?
        )
    ) {
        self.respond = respond
    }

    /// Answers every request with the same status and JSON body.
    public init(status: Int, json: String) {
        self.init { _, _, _, _ in
            (
                HTTPResponse(
                    status: .init(code: status),
                    headerFields: [.contentType: "application/json"]
                ),
                HTTPBody(json)
            )
        }
    }

    /// Fails every request, as an unreachable server would.
    public static func failing(_ error: any Error = URLError(.cannotConnectToHost)) -> StubTransport {
        StubTransport { _, _, _, _ in throw error }
    }

    public func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        recorder.record(Recorded(request: request, baseURL: baseURL))
        return try await respond(request, body, baseURL, operationID)
    }
}

extension VictualClient {
    /// A client wired to `transport`, for tests.
    public static func stubbed(
        _ transport: StubTransport,
        server: VictualServer = VictualServer(instanceURL: URL(string: "https://victual.test")!),
        apiKey: VictualAPIKey = "test-key"
    ) -> VictualClient {
        VictualClient(server: server, apiKey: apiKey, transport: transport)
    }
}

/// A `/system/info` body matching the shape the specification documents.
public let systemInfoJSON = """
    {
      "victual_version": { "Version": "4.2.0", "ReleaseDate": "2025-11-02" },
      "php_version": "8.3.14",
      "sqlite_version": "",
      "database_engine": "PostgreSQL 16.10"
    }
    """
