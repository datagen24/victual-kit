import Foundation
import VictualAPI

/// Somewhere stock is kept.
///
/// Locations form a tree at most six levels deep. ``path`` is the server's own
/// rendering of a location's place in that tree, read from the
/// `locations_resolved` view rather than reassembled here — see
/// ``VictualClient/locationPaths()``.
public struct StorageLocation: Hashable, Sendable, Identifiable, Codable {
    public var id: Int
    public var name: String
    public var details: String?

    /// The location this one sits inside, or `nil` for a root location.
    public var parentID: Int?

    /// The display path from this location's root, names joined by `" / "`.
    ///
    /// `nil` until ``VictualClient/locationPaths()`` has been fetched and merged
    /// in; a location with no path is shown by ``name`` alone.
    public var path: String?

    /// The deepest name in ``path``, which is ``name`` when a path is known.
    public var displayName: String { name.isEmpty ? "Location \(id)" : name }

    public init(
        id: Int,
        name: String,
        details: String? = nil,
        parentID: Int? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.parentID = parentID
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case details = "description"
        case parentID = "parent_location_id"
    }
}

extension StorageLocation {
    init?(_ schema: Components.Schemas.Location) {
        guard let id = schema.id else { return nil }
        self.init(
            id: id,
            name: schema.name ?? "",
            details: schema.description,
            parentID: schema.parentLocationId
        )
    }
}

/// One row of the `locations_resolved` view.
///
/// The view is a closure table: one row per (ancestor, descendant) pair,
/// including every location paired with itself at depth 0. Only the depth-0
/// rows are useful for a path, since `path` is the same string on every row for
/// a given descendant.
struct ResolvedLocationPath: Decodable, Sendable {
    var descendantLocationID: Int
    var depth: Int
    var path: String?

    enum CodingKeys: String, CodingKey {
        case descendantLocationID = "descendant_location_id"
        case depth
        case path
    }
}
