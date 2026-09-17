import Foundation
import OpenAPIRuntime

/// Every failure ``VictualClient`` can report, in terms a user interface can act on.
///
/// The generated client throws `ClientError` and surfaces documented error
/// responses as enum cases; this type collapses both into one set of cases so a
/// view does not have to pattern-match the generated shapes.
public enum VictualError: Error, Sendable {
    /// The text entered for the instance address was not a usable http(s) URL.
    case invalidServerURL(String)

    /// The server rejected the API key, or no key was supplied.
    case unauthorized

    /// The key is valid but lacks the permission this endpoint requires.
    case forbidden

    /// The requested object does not exist.
    case notFound

    /// The server rejected the request. `message` is the server's explanation
    /// when it sent one.
    case badRequest(message: String?)

    /// The server failed while handling an otherwise valid request.
    case serverError(statusCode: Int, message: String?)

    /// A status code the specification does not document for this operation.
    case unexpectedStatus(statusCode: Int)

    /// The response did not match the shape the specification promises.
    case decodingFailed(underlying: any Error)

    /// The request never reached the server, or the connection dropped.
    case transportFailed(underlying: any Error)

    /// Maps a thrown error from the generated client onto this type.
    ///
    /// Anything already a `VictualError` passes through unchanged, so wrapper
    /// methods can throw directly without being re-wrapped by their caller.
    public static func mapping(_ error: any Error) -> VictualError {
        if let victual = error as? VictualError { return victual }

        guard let clientError = error as? ClientError else {
            return .transportFailed(underlying: error)
        }
        let underlying = clientError.underlyingError
        if let victual = underlying as? VictualError { return victual }
        if underlying is DecodingError || underlying is EncodingError {
            return .decodingFailed(underlying: underlying)
        }
        if underlying is URLError || underlying is CancellationError {
            return .transportFailed(underlying: underlying)
        }
        // Everything else out of the runtime -- unexpected content types,
        // unexpected response cases, body conversion failures -- is the
        // response not matching what the specification promised.
        return .decodingFailed(underlying: underlying)
    }

    /// Builds the case matching an HTTP status code.
    public static func forStatus(_ statusCode: Int, message: String? = nil) -> VictualError {
        switch statusCode {
        case 400, 409, 422: return .badRequest(message: message)
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 500...599: return .serverError(statusCode: statusCode, message: message)
        default: return .unexpectedStatus(statusCode: statusCode)
        }
    }

    /// Whether retrying the identical request could plausibly succeed.
    ///
    /// Authentication and validation failures are excluded: they need the user
    /// to change something first.
    public var isRetryable: Bool {
        switch self {
        case .transportFailed, .serverError:
            return true
        case .invalidServerURL, .unauthorized, .forbidden, .notFound, .badRequest,
            .unexpectedStatus, .decodingFailed:
            return false
        }
    }
}

extension VictualError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidServerURL(let text):
            return "\"\(text)\" is not a valid Victual address."
        case .unauthorized:
            return "The API key was not accepted."
        case .forbidden:
            return "This API key does not have permission for that."
        case .notFound:
            return "That item no longer exists on the server."
        case .badRequest(let message):
            return message ?? "The server rejected the request."
        case .serverError(let statusCode, let message):
            return message ?? "The server reported an error (HTTP \(statusCode))."
        case .unexpectedStatus(let statusCode):
            return "The server returned an unexpected response (HTTP \(statusCode))."
        case .decodingFailed:
            return "The server's response could not be read."
        case .transportFailed(let underlying):
            return "Could not reach the server: \(underlying.localizedDescription)"
        }
    }
}

extension VictualError: Equatable {
    /// Compares cases structurally.
    ///
    /// The two cases that carry an arbitrary `any Error` fall back to
    /// `NSError` identity — domain, code and user info — which is what makes
    /// `state.error == .unauthorized` style checks usable from a view without
    /// giving up the underlying error for diagnostics.
    public static func == (lhs: VictualError, rhs: VictualError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidServerURL(let a), .invalidServerURL(let b)):
            return a == b
        case (.unauthorized, .unauthorized),
            (.forbidden, .forbidden),
            (.notFound, .notFound):
            return true
        case (.badRequest(let a), .badRequest(let b)):
            return a == b
        case (.serverError(let aCode, let aMessage), .serverError(let bCode, let bMessage)):
            return aCode == bCode && aMessage == bMessage
        case (.unexpectedStatus(let a), .unexpectedStatus(let b)):
            return a == b
        case (.decodingFailed(let a), .decodingFailed(let b)),
            (.transportFailed(let a), .transportFailed(let b)):
            return a as NSError == b as NSError
        default:
            return false
        }
    }
}
