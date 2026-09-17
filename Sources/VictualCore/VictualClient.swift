import Foundation
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
        self.server = server
        self.underlying = VictualAPIClient(
            serverURL: server.baseURL,
            transport: transport,
            middlewares: [APIKeyAuthenticationMiddleware(apiKey)] + middlewares
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
}
