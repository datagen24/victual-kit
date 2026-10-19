import Foundation
import VictualAPI

/// The key that makes a stock booking safe to retry.
///
/// Since 0.5.0 a server can remember a booking by a key the client chose, for a
/// while (ADR-0046). A retry carrying the same key and the same contents is
/// answered with the original booking instead of booking again, so a booking
/// whose outcome is unknown — the request went out, no answer came back — can
/// be sent again without risking a second one.
///
/// One key per *intended* booking: mint it before the first attempt, reuse it
/// for every retry of that booking, and never for a different one. The server
/// refuses a key reused with different contents (``VictualError/idempotencyConflict(message:)``).
public struct StockBookingKey: Hashable, Sendable, CustomStringConvertible {
    /// The value sent in the `Idempotency-Key` header.
    public let rawValue: String

    /// A new random key.
    ///
    /// A UUID: Foundation draws it from the system's cryptographic random
    /// source, as the server requires, and its 36 characters fit the header's
    /// grammar.
    public init() {
        rawValue = UUID().uuidString
    }

    /// A key with a given value, or `nil` when the value does not fit the
    /// header's grammar: 8 to 128 of `A-Z a-z 0-9 . _ : -`.
    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    static func isValid(_ value: String) -> Bool {
        (8...128).contains(value.count)
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || "._:-".unicodeScalars.contains(scalar))
            }
    }
}

/// One of the five stock bookings, as the server names it when it says which
/// of them honour a ``StockBookingKey``.
public enum StockBookingOperation: String, Hashable, Sendable, CaseIterable {
    case purchase
    case consume
    case transfer
    case open
    case inventory
}

/// Whether, and for how long, a server honours ``StockBookingKey``.
///
/// Read from `stock_booking_idempotency` in `GET /system/info`. A server that
/// does not publish it ignores the header and books on every request, so a
/// booking whose outcome is unknown must not be retried against it — not even
/// with the same key.
public struct StockBookingIdempotency: Hashable, Sendable {
    /// The operations a key protects.
    public var operations: Set<StockBookingOperation>

    /// How long after the first attempt the server will still recognise a key.
    ///
    /// Read from the server rather than assumed: the maintainer may change it.
    /// Past it, a retry with the same key books again, so a client must stop
    /// retrying, counting from the first send rather than from the last failure.
    public var retention: TimeInterval

    public init(operations: Set<StockBookingOperation>, retention: TimeInterval) {
        self.operations = operations
        self.retention = retention
    }

    /// Whether a key sent with `operation` is honoured.
    public func protects(_ operation: StockBookingOperation) -> Bool {
        operations.contains(operation)
    }
}

extension StockBookingIdempotency {
    init(_ payload: Operations.GetSystemInfo.Output.Ok.Body.JsonPayload.StockBookingIdempotencyPayload) {
        self.init(
            operations: Set(payload.operations.compactMap { StockBookingOperation(rawValue: $0.rawValue) }),
            retention: TimeInterval(payload.retentionSeconds.rawValue)
        )
    }
}

/// What this client has learned about the server's idempotency support.
///
/// A reference type for the same reason as ``InstanceClock``: every copy of a
/// ``VictualClient`` should know as soon as any of them has asked.
final class BookingIdempotencyKnowledge: @unchecked Sendable {
    private let lock = NSLock()
    private var learned: StockBookingIdempotency??

    /// `nil` while unknown; `.some(nil)` once the server is known not to
    /// publish the capability.
    var value: StockBookingIdempotency?? {
        get { lock.withLock { learned } }
        set { lock.withLock { learned = newValue } }
    }
}

extension VictualClient {
    /// Whether the server honours ``StockBookingKey``, and for how long.
    ///
    /// Asks `GET /system/info` the first time and remembers the answer for this
    /// client and every copy of it. ``verifyConnection()`` asks as a side
    /// effect, so a connected client usually knows already.
    ///
    /// - Returns: `nil` for a server that does not publish the capability.
    public func stockBookingIdempotency() async throws(VictualError) -> StockBookingIdempotency? {
        if let known = bookingIdempotency.value { return known }
        return try await systemInfo().stockBookingIdempotency
    }

    /// What the client has already learned about ``StockBookingKey`` support,
    /// without asking: `nil` when the server does not honour keys, or when no
    /// booking or ``systemInfo()`` has asked yet.
    public var knownStockBookingIdempotency: StockBookingIdempotency? {
        bookingIdempotency.value ?? nil
    }

    /// The header value to send with a booking: the key, when the server is
    /// known to honour it for `operation`, and nothing otherwise.
    ///
    /// Sending a key to a server that ignores it would do no harm on the wire,
    /// but it would let a caller believe a retry is safe when it is not, so the
    /// key goes only where it is honoured. A failure to learn the capability
    /// does not fail the booking: it goes without a key, as it did before 0.5.0.
    /// Only a transport failure is left unremembered, so the next keyed booking
    /// asks again.
    func idempotencyHeader(
        _ key: StockBookingKey?,
        for operation: StockBookingOperation
    ) async -> String? {
        guard let key else { return nil }
        let capability: StockBookingIdempotency?
        do {
            capability = try await stockBookingIdempotency()
        } catch {
            if case .transportFailed = error {
                return nil
            }
            bookingIdempotency.value = .some(nil)
            return nil
        }
        return capability?.protects(operation) == true ? key.rawValue : nil
    }
}
