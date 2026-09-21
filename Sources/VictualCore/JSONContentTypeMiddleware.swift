import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sends `Content-Type: application/json` with no parameters.
///
/// `swift-openapi-runtime` sets `application/json; charset=utf-8`, which is a
/// perfectly legal media type — RFC 9110 allows parameters, and a receiver is
/// meant to parse the type rather than compare the header as a string. Victual
/// compares it as a string:
///
/// ```php
/// if ($request->getHeaderLine('Content-Type') != 'application/json')
/// {
///     throw new HttpException($request, 'Bad Content-Type', 400);
/// }
/// ```
///
/// (`controllers/Api/BaseApiController.php`, `GetParsedAndFilteredRequestBody`.)
/// So without this, **every write this package makes is answered `400 Bad
/// Content-Type`** — all five bookings, and every object creation. Reads are
/// unaffected, because they carry no body.
///
/// The parameter is dropped rather than the whole header rewritten: a request
/// whose body is genuinely not JSON — a multipart file upload, say — keeps its
/// own type untouched. The charset is no loss either way, since JSON is UTF-8
/// by definition (RFC 8259 §8.1).
///
/// This is worth fixing upstream too: the comparison should parse the media
/// type. Until it does, and for as long as instances run a version that does
/// not, this shim is what makes the package usable for anything but reading.
struct JSONContentTypeMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let contentType = request.headerFields[.contentType],
            Self.isParameterizedJSON(contentType)
        {
            request.headerFields[.contentType] = "application/json"
        }
        return try await next(request, body, baseURL)
    }

    /// Whether `value` is `application/json` carrying at least one parameter.
    ///
    /// Matched on the media type alone, so `application/json` already bare is
    /// left as it is and a subtype such as `application/merge-patch+json` —
    /// which the server compares against its own literal, if at all — is not
    /// silently retyped.
    static func isParameterizedJSON(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: ";") else { return false }
        let mediaType = value[value.startIndex..<separator]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return mediaType == "application/json"
    }
}
