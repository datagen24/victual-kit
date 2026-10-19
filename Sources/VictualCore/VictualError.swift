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

    /// A write was sent and the server did not answer in time, or the connection
    /// dropped while waiting.
    ///
    /// The booking may have been recorded. Treat it as neither done nor failed.
    ///
    /// Sending it again is safe only with the same ``StockBookingKey``, the same
    /// contents, a server whose ``StockBookingIdempotency`` protects the
    /// operation, and inside its retention counted from the first attempt: the
    /// server then answers with the original booking rather than booking again.
    /// Otherwise do not send it again — a new key, or a server that ignores
    /// keys, books twice — and find the answer in the stock and its history,
    /// which a screen should refresh.
    case outcomeUnknown(underlying: any Error)

    /// The server already holds this ``StockBookingKey`` for a booking with
    /// different contents (`409 idempotency_conflict`).
    ///
    /// A client defect: nothing was booked by this request, and nothing says
    /// whether the earlier one was. Do not send it again.
    case idempotencyConflict(message: String?)

    /// The server is still working on an earlier request with this
    /// ``StockBookingKey`` (`409 idempotency_in_progress`).
    ///
    /// Nothing was booked by this request. Retry later with the same key and
    /// the same contents — never a new key, which would book a second time.
    case idempotencyInProgress(message: String?)

    /// Maps a failure of a *write* onto this type.
    ///
    /// A timeout or a dropped connection after sending leaves the outcome
    /// unknown; every other failure is mapped as ``mapping(_:)`` does. A refused
    /// connection or a missing network means nothing was sent, so those stay
    /// ordinary transport failures that are safe to retry.
    public static func writeFailure(_ error: any Error) -> VictualError {
        let mapped = mapping(error)
        guard case .transportFailed(let underlying) = mapped,
            let urlError = underlying as? URLError,
            urlError.code == .timedOut || urlError.code == .networkConnectionLost
        else { return mapped }
        return .outcomeUnknown(underlying: underlying)
    }

    /// Whether this is ``outcomeUnknown(underlying:)``.
    public var isOutcomeUnknown: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }

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
        // From 0.4.4 every documented error response declares a JSON body. One
        // that arrives without it -- a bare 401 from a reverse proxy, an HTML
        // 502 page -- fails to decode, but its status still says what went
        // wrong, and "the key was not accepted" is worth more to a person than
        // "the response could not be read".
        if let status = clientError.response?.status.code, status >= 400,
            !(underlying is URLError || underlying is CancellationError)
        {
            return forStatus(status)
        }
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
    /// to change something first. ``idempotencyInProgress(message:)`` is
    /// included, but "identical" there includes the key.
    /// ``outcomeUnknown(underlying:)`` is not: whether it may be retried
    /// depends on the key and the server, which the error cannot see.
    public var isRetryable: Bool {
        switch self {
        case .transportFailed, .serverError, .idempotencyInProgress:
            return true
        case .invalidServerURL, .outcomeUnknown, .unauthorized, .forbidden, .notFound, .badRequest,
            .unexpectedStatus, .decodingFailed, .idempotencyConflict:
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
        case .outcomeUnknown:
            return "The server did not answer in time, so it is not known whether that was recorded. Stock has been refreshed. Check it before trying again."
        case .idempotencyConflict(let message):
            return message ?? "The server already recorded a different booking under this request's key, so nothing was booked."
        case .idempotencyInProgress(let message):
            return message ?? "The server is still recording this booking. Try again in a moment."
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
        case (.badRequest(let a), .badRequest(let b)),
            (.idempotencyConflict(let a), .idempotencyConflict(let b)),
            (.idempotencyInProgress(let a), .idempotencyInProgress(let b)):
            return a == b
        case (.serverError(let aCode, let aMessage), .serverError(let bCode, let bMessage)):
            return aCode == bCode && aMessage == bMessage
        case (.unexpectedStatus(let a), .unexpectedStatus(let b)):
            return a == b
        case (.decodingFailed(let a), .decodingFailed(let b)),
            (.transportFailed(let a), .transportFailed(let b)),
            (.outcomeUnknown(let a), .outcomeUnknown(let b)):
            return a as NSError == b as NSError
        default:
            return false
        }
    }
}
