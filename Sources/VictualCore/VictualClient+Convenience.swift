import Foundation
import OpenAPIRuntime
import VictualAPI

/// A small, hand-written surface over the endpoints a front end needs before it
/// can show anything at all.
///
/// This is deliberately not a mirror of the whole API — the generated client on
/// ``VictualClient/underlying`` already covers every operation in the
/// specification. What lives here are the calls that a connection flow needs,
/// written in the shape the rest of the package expects: ``VictualError`` on
/// failure, plain Swift values on success.
///
/// Use these as the pattern when you add more. The stock reads and the five
/// bookings follow it, in `VictualClient+Stock.swift` and
/// `VictualClient+Bookings.swift`.
extension VictualClient {
    /// Version and runtime information about the instance.
    public func systemInfo() async throws(VictualError) -> SystemInformation {
        try await perform {
            try await underlying.getSystemInfo(.init())
        } unwrap: { output in
            switch output {
            case .ok(let response):
                let payload = try response.body.json
                return SystemInformation(
                    victualVersion: payload.victualVersion?.version,
                    releaseDate: payload.victualVersion?.releaseDate,
                    phpVersion: payload.phpVersion,
                    databaseEngine: payload.databaseEngine
                )
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }


    /// Performs the cheapest authenticated round trip, to confirm the address
    /// really is a Victual instance and the key is accepted — and, alongside
    /// it, learns the instance's time zone.
    ///
    /// Returns the instance's ``SystemInformation`` so a connection screen can
    /// show what it just connected to. The time zone is best-effort: failing to
    /// learn it does not fail the connection, it only leaves zone-less
    /// timestamps read in the device's zone.
    ///
    /// It is also bounded. Once the instance has answered, verification waits
    /// at most ``timeZoneGracePeriod`` more for the zone, so a stalled
    /// `/system/time` cannot hold a successful connection for a URL session's
    /// full timeout. A lookup still running then is left to finish, and
    /// stores the zone when it does.
    @discardableResult
    public func verifyConnection() async throws(VictualError) -> SystemInformation {
        try await verifyConnection(timeZoneGracePeriod: Self.timeZoneGracePeriod)
    }

    /// How long a successful verification waits for the time zone.
    static let timeZoneGracePeriod: Duration = .seconds(2)

    /// ``verifyConnection()`` with the grace period injectable, for tests.
    func verifyConnection(
        timeZoneGracePeriod: Duration
    ) async throws(VictualError) -> SystemInformation {
        let client = self
        let zoneLookup = Task { _ = try? await client.loadServerTimeZone() }
        let information: SystemInformation
        do {
            information = try await systemInfo()
        } catch {
            zoneLookup.cancel()
            throw error
        }
        await Self.wait(for: zoneLookup, atMost: timeZoneGracePeriod)
        return information
    }

    /// Returns when `task` finishes or `limit` passes, whichever is first,
    /// without cancelling `task`.
    ///
    /// Not a task group: a group waits for every child, and awaiting another
    /// task's `value` does not stop on cancellation, so a group would wait out
    /// the slow task after all.
    static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await task.value
                once.resume(continuation)
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(continuation)
            }
        }
    }

    /// Asks the instance which time zone it renders local timestamps in, and
    /// remembers it for this client and every copy of it.
    ///
    /// The server renders `row_created_timestamp`, `changed_time` and the like
    /// as `"YYYY-MM-DD HH:MM:SS"` in its configured zone, with no offset. Read
    /// in the device's zone instead, every such instant shifts by the
    /// difference — the phone of someone travelling, or a server configured in
    /// UTC.
    ///
    /// - Returns: The zone, or `nil` when the server named one Foundation does
    ///   not know — in which case nothing is remembered.
    @discardableResult
    public func loadServerTimeZone() async throws(VictualError) -> TimeZone? {
        let zone: TimeZone? = try await perform {
            try await underlying.getSystemTime(.init())
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return try response.body.json.timezone.flatMap(TimeZone.init(identifier:))
            case .badRequest(let response):
                throw VictualError.badRequest(message: try? response.body.json.errorMessage)
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
        if let zone { clock.timeZone = zone }
        return zone
    }

    /// Runs a generated operation and narrows every failure to ``VictualError``.
    ///
    /// The generated client throws `ClientError` for transport and coding
    /// failures, and the generated `.ok` / `.json` accessors throw when the
    /// response was a different case than expected. Both funnel through
    /// ``VictualError/mapping(_:)`` here so callers only ever see one error type.
    ///
    /// Internal rather than private so the wrappers in `VictualClient+Stock.swift`
    /// and `VictualClient+Bookings.swift` share it; it stays out of the package's
    /// public surface because its `Output` is always a generated type.
    ///
    /// Both the call and the unwrap run with the instance's time zone bound, so
    /// whatever timestamps they decode are read in it. See
    /// ``VictualDates/serverTimeZone``.
    func perform<Output, Value>(
        _ call: () async throws -> Output,
        unwrap: (Output) throws -> Value
    ) async throws(VictualError) -> Value {
        do {
            return try await VictualDates.$serverTimeZone.withValue(clock.timeZone) {
                try unwrap(try await call())
            }
        } catch {
            throw VictualError.mapping(error)
        }
    }
}

/// Version and runtime details reported by `GET /system/info`.
public struct SystemInformation: Hashable, Sendable {
    /// The Victual release running on the instance, when it reports one.
    public var victualVersion: String?

    /// The release date, as the server formats it (`YYYY-MM-DD`).
    ///
    /// Kept as text: the specification types it `format: date`, but the field is
    /// free-form enough upstream that parsing it here would turn a cosmetic
    /// detail into a connection failure.
    public var releaseDate: String?

    public var phpVersion: String?

    /// The database engine and version serving the instance, for example
    /// `"PostgreSQL 16.10"`.
    public var databaseEngine: String?

    public init(
        victualVersion: String? = nil,
        releaseDate: String? = nil,
        phpVersion: String? = nil,
        databaseEngine: String? = nil
    ) {
        self.victualVersion = victualVersion
        self.releaseDate = releaseDate
        self.phpVersion = phpVersion
        self.databaseEngine = databaseEngine
    }
}

/// Resumes a continuation the first time it is asked to, and ignores the rest.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        let first = lock.withLock {
            defer { resumed = true }
            return !resumed
        }
        if first { continuation.resume() }
    }
}
