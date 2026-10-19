import VictualAPI

/// The error responses the 0.4.4 document shares between operations.
///
/// Every operation now declares `500` and `503`, and most declare `400` and
/// `403` as well, each as a reference to one shared response. These build the
/// matching ``VictualError`` once, so the wrappers' switches stay one line per
/// case and the message the server sent is kept wherever it sent one.
extension VictualError {
    /// `400`: a path parameter that must be an integer was not one.
    static func from(_ response: Components.Responses.InvalidPathParameter) -> VictualError {
        .badRequest(message: try? response.body.json.errorMessage)
    }

    /// `403`: the key lacks a permission the route requires, or middleware
    /// refused it (a read-only key on a write, for one).
    static func from(_ response: Components.Responses.Forbidden) -> VictualError {
        _ = response
        return .forbidden
    }

    /// `404` with the shared `ApiError` body.
    static func from(_ response: Components.Responses.NotFound) -> VictualError {
        _ = response
        return .notFound
    }

    /// `401` with the shared `ApiError` body.
    static func from(_ response: Components.Responses.Unauthorized) -> VictualError {
        _ = response
        return .unauthorized
    }

    /// `500`: an uncaught server error. `error_message` is for a person to
    /// read; the document says it is not a stable code.
    static func from(_ response: Components.Responses.ServerError) -> VictualError {
        .serverError(statusCode: 500, message: try? response.body.json.errorMessage)
    }

    /// `503`: the schema-version gate refused the request before routing,
    /// because the database could not be queried or its migrations do not
    /// match the running code.
    ///
    /// The plain-text body says which, but reading it is asynchronous and the
    /// wrappers unwrap synchronously, so the message is the document's own
    /// account of this response. A 503 that is not this one -- a reverse proxy
    /// with nothing behind it -- keeps the generic wording instead.
    static func from(_ response: Components.Responses.SchemaUnavailable) -> VictualError {
        _ = response
        return .serverError(
            statusCode: 503,
            message: "The server's database is unavailable or is being updated. Try again shortly."
        )
    }

    /// `409` from a stock booking: the server's idempotency check refused it.
    ///
    /// Each booking route generates its own enum for the code, so this takes
    /// the raw value. A code this package does not know stays a refusal.
    static func idempotency(code: String, message: String?) -> VictualError {
        switch code {
        case "idempotency_conflict": .idempotencyConflict(message: message)
        case "idempotency_in_progress": .idempotencyInProgress(message: message)
        default: .badRequest(message: message)
        }
    }
}
