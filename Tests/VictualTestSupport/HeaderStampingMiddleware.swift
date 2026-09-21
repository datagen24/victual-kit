import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A middleware that marks every request it sees.
///
/// Used to prove that a request made outside the generated client still goes
/// through the chain the caller configured.
public struct HeaderStampingMiddleware: ClientMiddleware {
    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var stamped = request
        stamped.headerFields[.userAgent] = "victual-kit-test"
        return try await next(stamped, body, baseURL)
    }
}
