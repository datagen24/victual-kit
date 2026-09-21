import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import VictualAPI

/// A configured connection to one Victual instance.
///
/// The value is `Sendable` and cheap to copy, so it can be held by an observable
/// store on the main actor and used from any task.
///
/// ```swift
/// let client = try VictualClient(
///     server: VictualServer(userEnteredText: "victual.example.com"),
///     apiKey: "…"
/// )
/// let info = try await client.systemInfo()
/// ```
///
/// Endpoints without a convenience method here are reachable through
/// ``underlying``, which is the full generated client.
public struct VictualClient: Sendable {
    /// The instance this client talks to.
    public let server: VictualServer

    /// The generated OpenAPI client, already carrying authentication.
    public let underlying: VictualAPIClient

    /// The transport and middlewares the generated client was built over.
    ///
    /// Kept so that ``listObjects(_:as:)`` can reach `GET /objects/{entity}`,
    /// whose generated response type cannot represent what that route returns.
    /// See that method for why.
    let channel: Channel

    /// Creates a client over an explicit transport.
    ///
    /// Use this to inject a stub transport in tests, or a transport other than
    /// `URLSession`.
    public init(
        server: VictualServer,
        apiKey: VictualAPIKey,
        transport: any ClientTransport,
        middlewares: [any ClientMiddleware] = []
    ) {
        // The content-type shim runs outermost so that it sees, and can
        // correct, whatever the runtime set -- see ``JSONContentTypeMiddleware``
        // for why a request without it is refused by the server.
        let authenticated: [any ClientMiddleware] =
            [JSONContentTypeMiddleware(), APIKeyAuthenticationMiddleware(apiKey)] + middlewares
        self.server = server
        self.underlying = VictualAPIClient(
            serverURL: server.baseURL,
            // Victual renders `format: date-time` fields the way its database
            // stores them, which is not ISO 8601. See ``VictualDates``.
            configuration: .init(dateTranscoder: VictualDates.transcoder),
            transport: transport,
            middlewares: authenticated
        )
        self.channel = Channel(
            baseURL: server.baseURL,
            transport: transport,
            middlewares: authenticated
        )
    }

    /// Creates a client backed by `URLSession`.
    public init(
        server: VictualServer,
        apiKey: VictualAPIKey,
        session: URLSession = .shared,
        middlewares: [any ClientMiddleware] = []
    ) {
        self.init(
            server: server,
            apiKey: apiKey,
            transport: URLSessionTransport(
                configuration: .init(session: session)
            ),
            middlewares: middlewares
        )
    }

    /// The transport plus its middleware chain, as the generated client sees it.
    ///
    /// The generated `Client` keeps its own copy privately, so a request made
    /// outside it — there is exactly one — needs this to go through the same
    /// authentication and any middleware the caller supplied.
    struct Channel: Sendable {
        let baseURL: URL
        let transport: any ClientTransport
        let middlewares: [any ClientMiddleware]

        /// Sends a request through the middleware chain, outermost first.
        ///
        /// Mirrors `UniversalClient`: each middleware wraps the next, and the
        /// transport is the innermost call.
        func send(
            _ request: HTTPRequest,
            body: HTTPBody?,
            operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            var next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (
                HTTPResponse, HTTPBody?
            ) = { request, body, baseURL in
                try await transport.send(
                    request,
                    body: body,
                    baseURL: baseURL,
                    operationID: operationID
                )
            }
            for middleware in middlewares.reversed() {
                let inner = next
                next = { request, body, baseURL in
                    try await middleware.intercept(
                        request,
                        body: body,
                        baseURL: baseURL,
                        operationID: operationID,
                        next: inner
                    )
                }
            }
            return try await next(request, body, baseURL)
        }
    }
}
