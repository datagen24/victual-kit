import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The `Idempotency-Key` request header, as a field name.
public let idempotencyKeyField = HTTPField.Name("Idempotency-Key")!

/// A `/system/info` body that publishes `stock_booking_idempotency`, as a 0.5.0
/// server does, for the given operations. `nil` leaves the block out, as every
/// earlier server does.
public func systemInfoJSON(idempotentOperations operations: [String]?) -> String {
    guard let operations else { return systemInfoJSON }
    let list = operations.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
        {
          "victual_version": { "Version": "0.5.0", "ReleaseDate": "2026-10-18" },
          "database_engine": "PostgreSQL 16.10",
          "stock_booking_idempotency": {
            "header": "Idempotency-Key",
            "retention_seconds": 604800,
            "operations": [\(list)]
          }
        }
        """
}

/// One answer a booking route gives, in the order the stub hands them out.
public enum BookingAnswer: Sendable {
    /// `200` with the rows, and `Idempotent-Replayed` when given.
    case booked(replayed: Bool?)
    /// `409` with one of the two idempotency codes.
    case conflict(code: String)
    /// No answer: the request went out and the connection gave up waiting.
    case timedOut
}

extension StubTransport {
    /// A server that answers `/system/info` with `systemInfo` and each booking
    /// with the next of `answers`, the last repeating.
    public static func bookingServer(
        systemInfo: String,
        answers: [BookingAnswer],
        rows: String = #"[{"id":1,"product_id":7,"amount":-1,"transaction_id":"tx-1","transaction_type":"consume"}]"#
    ) -> StubTransport {
        let queue = AnswerQueue(answers)
        return StubTransport { request, _, _, _ in
            let path = request.path ?? ""
            if path.hasPrefix("/system/info") {
                return (
                    HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                    HTTPBody(systemInfo)
                )
            }
            switch queue.next() {
            case .booked(let replayed):
                var fields: HTTPFields = [.contentType: "application/json"]
                if let replayed {
                    fields[HTTPField.Name("Idempotent-Replayed")!] = replayed ? "true" : "false"
                }
                return (HTTPResponse(status: .ok, headerFields: fields), HTTPBody(rows))
            case .conflict(let code):
                return (
                    HTTPResponse(status: .conflict, headerFields: [.contentType: "application/json"]),
                    HTTPBody(#"{"error_message":"refused: \#(code)","code":"\#(code)"}"#)
                )
            case .timedOut:
                throw URLError(.timedOut)
            }
        }
    }
}

extension StubTransport.Recorder {
    /// The booking requests, leaving out the `/system/info` the client asks
    /// before its first keyed booking.
    public var bookings: [StubTransport.Recorded] {
        requests.filter { $0.request.method == .post && $0.request.path?.hasPrefix("/stock/products/") == true }
    }
}

private final class AnswerQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [BookingAnswer]

    init(_ answers: [BookingAnswer]) {
        self.answers = answers
    }

    func next() -> BookingAnswer {
        lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] }
    }
}
