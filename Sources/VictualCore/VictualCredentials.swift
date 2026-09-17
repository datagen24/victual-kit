import Foundation
import HTTPTypes
import OpenAPIRuntime

/// An API key issued by a Victual instance.
///
/// The key is sent in the `VICTUAL-API-KEY` header, matching the `ApiKeyAuth`
/// security scheme in the OpenAPI document.
public struct VictualAPIKey: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public static let headerName: HTTPField.Name = .init("VICTUAL-API-KEY")!

    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Whether the key is non-empty. It says nothing about whether the server
    /// will accept it — only a request can establish that.
    public var isWellFormed: Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension VictualAPIKey: CustomStringConvertible {
    /// Redacted, so a key never reaches a log or a crash report by accident.
    public var description: String { "VictualAPIKey(••••)" }
}

/// Attaches the instance's API key to every outgoing request.
public struct APIKeyAuthenticationMiddleware: ClientMiddleware {
    private let key: VictualAPIKey

    public init(_ key: VictualAPIKey) {
        self.key = key
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[VictualAPIKey.headerName] = key.rawValue
        return try await next(request, body, baseURL)
    }
}
