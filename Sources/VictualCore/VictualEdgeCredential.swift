import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A Cloudflare Access service token, for an instance that sits behind Access.
///
/// Cloudflare checks it before a request reaches Victual, so it is a credential
/// for the *device*, not the user: the operator issues one per phone or Mac and
/// can revoke each on its own. It travels alongside the ``VictualAPIKey``,
/// which still decides who the user is, and never replaces it.
///
/// Optional, and per instance. Most instances are not behind Access and never
/// need one.
public struct VictualEdgeCredential: Hashable, Sendable, Codable {
    public static let clientIDHeaderName: HTTPField.Name = .init("CF-Access-Client-Id")!
    public static let clientSecretHeaderName: HTTPField.Name = .init("CF-Access-Client-Secret")!

    /// The token's Client ID, ending in `.access`.
    public var clientID: String

    /// The token's Client Secret. Newer secrets start with `cfast_`.
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Builds a credential from what a person typed or pasted, or `nil` when
    /// either field is empty.
    ///
    /// Whitespace is trimmed, since a pasted secret often carries a newline.
    /// One field without the other is not a credential, and is not the same as
    /// no token; ``isComplete(clientID:clientSecret:)`` is the check a form
    /// should make first.
    public static func entered(clientID: String, clientSecret: String) -> VictualEdgeCredential? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return VictualEdgeCredential(clientID: id, clientSecret: secret)
    }

    /// Whether a form's two fields make sense together: both filled, or both
    /// empty for an instance without a token.
    public static func isComplete(clientID: String, clientSecret: String) -> Bool {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty == secret.isEmpty
    }
}

extension VictualEdgeCredential: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted, so the secret never reaches a log or a crash report by
    /// accident. The Client ID is not secret on its own, and is what an
    /// operator needs to tell tokens apart.
    public var description: String { "VictualEdgeCredential(\(clientID), ••••)" }
    public var debugDescription: String { description }
}

/// Attaches a Cloudflare Access service token to every outgoing request.
///
/// A client's middleware only ever talks to its own instance, so the token is
/// never sent to another host — and the transport does not follow the
/// redirect Access answers with, so it is not carried there either.
public struct EdgeCredentialMiddleware: ClientMiddleware {
    private let credential: VictualEdgeCredential

    public init(_ credential: VictualEdgeCredential) {
        self.credential = credential
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[VictualEdgeCredential.clientIDHeaderName] = credential.clientID
        request.headerFields[VictualEdgeCredential.clientSecretHeaderName] = credential.clientSecret
        return try await next(request, body, baseURL)
    }
}

/// Turns a response from Cloudflare, rather than from Victual, into the
/// ``VictualError`` that says what actually happened.
///
/// Without it, an instance behind Cloudflare fails in misleading ways: a
/// firewall `403` reads as "this API key does not have permission", the
/// Access login page reads as a malformed response, and a tunnel that is down
/// reads as a server error. None of those bodies is JSON, and none came from
/// Victual.
///
/// Installed on every client, token or not. An instance that is not behind
/// Cloudflare never answers with any of these, and one that is but has no
/// token saved should say a token is needed.
struct EdgeResponseMiddleware: ClientMiddleware {
    static let rayHeaderName: HTTPField.Name = .init("cf-ray")!
    static let mitigatedHeaderName: HTTPField.Name = .init("cf-mitigated")!

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        if let failure = Self.edgeFailure(for: response) {
            throw failure
        }
        return (response, responseBody)
    }

    /// The edge failure `response` describes, or `nil` when it is Victual's own.
    ///
    /// Victual's errors are JSON from 0.4.4 on, and Cloudflare's are HTML, so a
    /// JSON body is never classified here even though Cloudflare sets
    /// `Server: cloudflare` on everything it proxies.
    static func edgeFailure(for response: HTTPResponse) -> VictualError? {
        let ray = response.headerFields[rayHeaderName]

        if response.headerFields[mitigatedHeaderName]?.lowercased() == "challenge" {
            return .edgeChallenged(rayID: ray)
        }
        if (300..<400).contains(response.status.code),
            let location = response.headerFields[.location],
            isAccessLogin(location)
        {
            return .edgeAccessRequired
        }

        let fromCloudflare = response.headerFields[.server]?.lowercased() == "cloudflare"
        let isJSON = response.headerFields[.contentType]?.lowercased().contains("json") ?? false
        guard fromCloudflare, !isJSON else { return nil }

        switch response.status.code {
        // Victual is only ever sent standard methods, so a firewall refusal
        // is about where the request came from.
        case 403: return .edgeBlocked(rayID: ray)
        // Error 1033: no tunnel connection, so nothing reached the origin.
        case 530: return .edgeUnreachable(rayID: ray, requestSent: false)
        // The origin was reached, or may have been, and then failed or went
        // quiet. A write may have been recorded.
        case 502, 520...524: return .edgeUnreachable(rayID: ray, requestSent: nil)
        default: return nil
        }
    }

    /// Whether `location` is a Cloudflare Access sign-in page.
    static func isAccessLogin(_ location: String) -> Bool {
        guard let host = URL(string: location)?.host?.lowercased() else { return false }
        return host.hasSuffix(".cloudflareaccess.com")
    }
}
