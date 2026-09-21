import Foundation
import HTTPTypes
import OpenAPIRuntime
import VictualAPI

/// Reads of `GET /objects/{entity}`, the generic entity listing.
///
/// ## Why this one route does not use the generated client
///
/// The specification types the response as an undiscriminated `oneOf` over nine
/// entity schemas, and the generator decodes such a union by trying each case in
/// declaration order and keeping the first that succeeds. `Product` is declared
/// first and has no required properties, so **every** row of every entity
/// decodes as a `Product` — a quantity unit arrives with its `name_plural`
/// discarded, and a `locations_resolved` row, whose schema is not in the union
/// at all, arrives with its `path` gone.
///
/// Those two fields are exactly what a stock list needs: an amount cannot be
/// rendered without a unit's plural, and the sidebar's locations tree is built
/// from `path`. So this file issues the request itself, through the same
/// transport and the same middleware chain the generated client uses, and
/// decodes into the hand-written row types below.
///
/// Everything else in ``VictualCore`` goes through the generated client, and
/// should. This is the one place where doing so would silently lose data.
extension VictualClient {
    /// Every quantity unit the instance defines, by id.
    ///
    /// Amounts cannot be rendered without these, and there are few enough of
    /// them that fetching them once beats fetching one per product.
    public func quantityUnits() async throws(VictualError) -> [QuantityUnit] {
        try await listObjects("quantity_units", as: QuantityUnit.self)
    }

    /// Every storage location the instance defines.
    ///
    /// ``StorageLocation/path`` is not filled here — it lives in a different
    /// view. Call ``locationPaths()`` and merge, or use ``locationTree()``.
    public func locations() async throws(VictualError) -> [StorageLocation] {
        try await listObjects("locations", as: StorageLocation.self)
    }

    /// Each location's display path from its own root, keyed by location id.
    ///
    /// `locations_resolved` is a closure table — one row per (ancestor,
    /// descendant) pair — and `path` is the same string on every row for a given
    /// descendant, so only the depth-0 rows are read.
    public func locationPaths() async throws(VictualError) -> [Int: String] {
        let rows = try await listObjects("locations_resolved", as: ResolvedLocationPath.self)
        var paths: [Int: String] = [:]
        for row in rows where row.depth == 0 {
            if let path = row.path, !path.isEmpty {
                paths[row.descendantLocationID] = path
            }
        }
        return paths
    }

    /// Locations with their display paths already merged in, sorted by path.
    ///
    /// Two requests, because the names and the tree live in different views.
    /// A location the resolved view has no row for keeps a `nil` path and sorts
    /// by its own name.
    public func locationTree() async throws(VictualError) -> [StorageLocation] {
        // `async let` erases the typed throw, so the two awaits are rejoined
        // through `mapping`, which passes a `VictualError` straight through.
        async let locationsTask = locations()
        async let pathsTask = locationPaths()
        var located: [StorageLocation]
        let paths: [Int: String]
        do {
            located = try await locationsTask
            paths = try await pathsTask
        } catch {
            throw VictualError.mapping(error)
        }
        for index in located.indices {
            located[index].path = paths[located[index].id]
        }
        return located.sorted {
            ($0.path ?? $0.name).localizedStandardCompare($1.path ?? $1.name) == .orderedAscending
        }
    }

    /// Lists one entity, decoding rows into `rowType`.
    ///
    /// Deliberately not generic over the entity name in a typed way: the
    /// specification's entity enum is a permissive string after normalization,
    /// and each caller above knows which row type its entity yields. Keeping the
    /// pairing in one small function per entity is what stops the undiscriminated
    /// union leaking out.
    func listObjects<Row: Decodable & Sendable>(
        _ entity: String,
        as rowType: Row.Type
    ) async throws(VictualError) -> [Row] {
        let request = HTTPRequest(
            method: .get,
            scheme: nil,
            authority: nil,
            // Server-relative, the way the generated client builds it: the
            // transport concatenates this onto the base URL's own path.
            path: "/objects/\(entity)",
            headerFields: [.accept: "application/json"]
        )

        let response: HTTPResponse
        let body: HTTPBody?
        do {
            (response, body) = try await channel.send(
                request,
                body: nil,
                operationID: "listObjects"
            )
        } catch {
            throw VictualError.mapping(error)
        }

        guard response.status.code == 200 else {
            throw VictualError.forStatus(
                response.status.code,
                message: try? await Self.errorMessage(from: body)
            )
        }

        let data: Data
        do {
            data = try await Data(collecting: body ?? HTTPBody(), upTo: Self.maximumBodyBytes)
        } catch {
            throw VictualError.transportFailed(underlying: error)
        }
        do {
            return try Self.objectDecoder.decode([Row].self, from: data)
        } catch {
            throw VictualError.decodingFailed(underlying: error)
        }
    }

    /// The server's explanation for a non-200, when it sent one.
    private static func errorMessage(from body: HTTPBody?) async throws -> String? {
        guard let body else { return nil }
        let data = try await Data(collecting: body, upTo: maximumBodyBytes)
        struct Failure: Decodable { var errorMessage: String? }
        return try? JSONDecoder.snakeCased.decode(Failure.self, from: data).errorMessage
    }

    /// An entity listing is a small table — units, locations — not a data dump.
    /// Four megabytes is far more than any of them, and still a bound.
    private static let maximumBodyBytes = 4 * 1_024 * 1_024

    /// The row types here spell out their own `CodingKeys`, so no key strategy
    /// is applied; the date strategy matches ``VictualDates`` for the few
    /// timestamp columns these views carry.
    private static let objectDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try VictualDates.transcoder.decode(text)
        }
        return decoder
    }()
}

extension JSONDecoder {
    fileprivate static let snakeCased: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
