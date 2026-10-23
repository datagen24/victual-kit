import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// How long a request may wait for the server before it is given up, by kind of
/// operation.
///
/// One limit cannot serve all of them. A read that has not answered in seconds
/// is not going to, and the person is watching a spinner; a write that has not
/// answered may still be running, and giving up early turns "slow" into "did it
/// happen?". `URLSession` applies the limit between bytes, so these bound the
/// wait for a response to start and any silence mid-way, not the whole transfer.
///
/// ## Where the numbers come from
///
/// Measured against the dev instance on a local network (Victual 0.4.0), five
/// runs each: reads answered in 0.07 to 0.33 s (`/stock/volatile` was the
/// slowest), writes in 0.19 to 0.51 s, and the consumption-event batch endpoint
/// in 0.10 s. The limits are 30 to 100 times those figures, so a phone on
/// mobile data or through a tunnel has room while a dead host still fails
/// inside the time a person will wait. Only the dev instance was measured; a
/// remote path was not.
public struct OperationTimeouts: Sendable, Hashable {
    /// `GET`, `HEAD` and `OPTIONS`.
    public var read: TimeInterval = 10

    /// Stock bookings and other writes. Longer than a read: the request may
    /// have been received, and an early timeout leaves its outcome unknown.
    public var write: TimeInterval = 30

    /// Medication synchronization (`/consumption/…` writes), which can carry a
    /// batch of events.
    public var synchronization: TimeInterval = 60

    public init() {}

    /// Which limit applies to a request.
    func limit(for request: HTTPRequest) -> TimeInterval {
        switch request.method {
        case .get, .head, .options:
            return read
        default:
            let path = request.path ?? ""
            return path.hasPrefix("/consumption/") ? synchronization : write
        }
    }
}

/// A transport that sends each request through a `URLSession` whose timeout
/// matches the kind of operation.
///
/// `URLSession`'s timeout lives on the session's configuration, not on a
/// request the generated client builds, so there is one session per limit.
struct TimeoutRoutingTransport: ClientTransport {
    private let timeouts: OperationTimeouts
    private let readTransport: URLSessionTransport
    private let writeTransport: URLSessionTransport
    private let synchronizationTransport: URLSessionTransport

    /// - Parameter protocolClasses: Prepended to each session's URL protocols.
    ///   For tests, which answer from a `URLProtocol` stub so that redirects
    ///   go through `URLSession` itself.
    init(timeouts: OperationTimeouts = OperationTimeouts(), protocolClasses: [AnyClass] = []) {
        self.timeouts = timeouts
        func transport(_ seconds: TimeInterval) -> URLSessionTransport {
            URLSessionTransport(
                configuration: .init(session: Self.session(timeout: seconds, protocolClasses: protocolClasses)))
        }
        self.readTransport = transport(timeouts.read)
        self.writeTransport = transport(timeouts.write)
        self.synchronizationTransport = transport(timeouts.synchronization)
    }

    /// A session for one limit.
    ///
    /// It keeps no cookies. Cloudflare Access answers a request carrying a
    /// service token with a `CF_Authorization` cookie good for a day, and a
    /// session that kept it would keep getting in on it after the token was
    /// revoked. Without it, every request is checked against the token. Victual
    /// itself needs no cookie for an API-key request.
    ///
    /// It also stops at a redirect to the Access sign-in page; see
    /// ``AccessRedirectGuard``.
    static func session(timeout: TimeInterval, protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration, delegate: AccessRedirectGuard(), delegateQueue: nil)
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let limit = timeouts.limit(for: request)
        let chosen =
            limit == timeouts.read
            ? readTransport : (limit == timeouts.write ? writeTransport : synchronizationTransport)
        return try await chosen.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}

/// Refuses to follow a redirect to a Cloudflare Access sign-in page.
///
/// Access answers a request without a valid service token with a `302` to its
/// login page. Followed, that becomes a `200` HTML page the generated client
/// cannot decode, and the reason is lost. Stopped here, the `302` itself comes
/// back, and ``EdgeResponseMiddleware`` reports it as
/// ``VictualError/edgeAccessRequired``. Every other redirect is followed as
/// before.
///
/// A session delegate rather than a task one: in streaming mode
/// `URLSessionTransport` gives each task its own delegate, which does not
/// handle redirects, so `URLSession` falls back to this one. A test covers it.
final class AccessRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let target = request.url?.absoluteString ?? ""
        completionHandler(EdgeResponseMiddleware.isAccessLogin(target) ? nil : request)
    }
}
