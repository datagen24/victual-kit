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
/// Use these as the pattern when you add more.
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

    /// Products currently in stock, with the next due date for each.
    ///
    /// Requires the `STOCK_VIEW` permission.
    public func currentStock() async throws(VictualError) -> [Components.Schemas.CurrentStockResponse] {
        try await perform {
            try await underlying.getCurrentStock(.init())
        } unwrap: { output in
            switch output {
            case .ok(let response):
                return try response.body.json
            case .unauthorized:
                throw VictualError.unauthorized
            case .undocumented(let statusCode, _):
                throw VictualError.forStatus(statusCode)
            }
        }
    }

    /// Performs the cheapest authenticated round trip, to confirm the address
    /// really is a Victual instance and the key is accepted.
    ///
    /// Returns the instance's ``SystemInformation`` so a connection screen can
    /// show what it just connected to.
    @discardableResult
    public func verifyConnection() async throws(VictualError) -> SystemInformation {
        try await systemInfo()
    }

    /// Runs a generated operation and narrows every failure to ``VictualError``.
    ///
    /// The generated client throws `ClientError` for transport and coding
    /// failures, and the generated `.ok` / `.json` accessors throw when the
    /// response was a different case than expected. Both funnel through
    /// ``VictualError/mapping(_:)`` here so callers only ever see one error type.
    private func perform<Output, Value>(
        _ call: () async throws -> Output,
        unwrap: (Output) throws -> Value
    ) async throws(VictualError) -> Value {
        let output: Output
        do {
            output = try await call()
        } catch {
            throw VictualError.mapping(error)
        }
        do {
            return try unwrap(output)
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
