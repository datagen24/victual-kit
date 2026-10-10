import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A response to ``VictualClient/send(_:path:query:body:operationID:)``.
public struct VictualRawResponse: Sendable {
    public let status: Int
    public let data: Data
}

extension VictualClient {
    /// Sends a request through the client's authentication and middleware, with
    /// a body the caller has already encoded.
    ///
    /// For the few calls that must put *exact* bytes on the wire: a medication
    /// event is stored in an outbox and replayed after a crash or a retry, and the
    /// server compares the payload hash, so re-encoding it through a generated
    /// request type (which would re-render timestamps in whatever offset applies
    /// now) could turn a safe replay into a conflict. Everything that does not
    /// need that goes through ``underlying``.
    ///
    /// A status of 400 or above is thrown as a ``VictualError`` carrying the
    /// server's `error_message`; the caller sees only successes.
    ///
    /// - Parameters:
    ///   - path: Server-relative, with a leading slash and no query.
    ///   - query: Name and value pairs; both are percent-encoded here.
    public func send(
        _ method: HTTPRequest.Method,
        path: String,
        query: [(name: String, value: String)] = [],
        body: Data? = nil,
        operationID: String
    ) async throws(VictualError) -> VictualRawResponse {
        var fields: HTTPFields = [.accept: "application/json"]
        if body != nil { fields[.contentType] = "application/json" }
        let request = HTTPRequest(
            method: method, scheme: nil, authority: nil,
            path: path + Self.queryString(query), headerFields: fields)

        do {
            let (response, responseBody) = try await channel.send(
                request, body: body.map { HTTPBody($0) }, operationID: operationID)
            let data = try await Data(collecting: responseBody ?? HTTPBody(), upTo: Self.rawMaximumBodyBytes)
            guard response.status.code < 400 else {
                throw VictualError.forStatus(response.status.code, message: Self.errorMessage(in: data))
            }
            return VictualRawResponse(status: response.status.code, data: data)
        } catch {
            throw VictualError.mapping(error)
        }
    }

    /// Decodes a response body with the date handling every generated type here
    /// expects, so a generated schema type can be read from bytes ``send`` returned.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(VictualError) -> T {
        do {
            return try VictualDates.$serverTimeZone.withValue(clock.timeZone) {
                try Self.rawDecoder.decode(T.self, from: data)
            }
        } catch {
            throw VictualError.decodingFailed(underlying: error)
        }
    }

    static func queryString(_ pairs: [(name: String, value: String)]) -> String {
        guard !pairs.isEmpty else { return "" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "[]=&+#")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return "?" + pairs.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")
    }

    private static func errorMessage(in data: Data) -> String? {
        struct Failure: Decodable {
            var errorMessage: String?
            enum CodingKeys: String, CodingKey { case errorMessage = "error_message" }
        }
        return try? JSONDecoder().decode(Failure.self, from: data).errorMessage
    }

    private static let rawMaximumBodyBytes = 4 * 1_024 * 1_024

    private static let rawDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try VictualDates.transcoder.decode(text)
        }
        return decoder
    }()
}
