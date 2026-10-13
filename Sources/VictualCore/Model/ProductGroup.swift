import Foundation

/// A product group, with the groups nested inside it.
///
/// Groups form a tree through `parent_product_group_id`. The server renders the
/// tree as the closure view `product_groups_resolved` — one row per (ancestor,
/// descendant) pair, each carrying the descendant's path — so a group's place
/// and its descendants are read, not reassembled. See
/// ``VictualClient/productGroups()``.
public struct ProductGroup: Hashable, Sendable, Identifiable {
    public var id: Int

    /// The names from the root down to this group, joined by `" / "`.
    public var path: String

    /// How many groups sit above this one. A root group is 0.
    public var depth: Int

    /// This group's id and every group nested inside it, at any depth.
    ///
    /// Choosing a parent in a filter includes the products of all of these.
    public var memberIDs: Set<Int>

    /// The deepest name in ``path``.
    public var name: String {
        path.components(separatedBy: " / ").last ?? path
    }

    public init(id: Int, path: String, depth: Int, memberIDs: Set<Int>) {
        self.id = id
        self.path = path
        self.depth = depth
        self.memberIDs = memberIDs
    }
}

/// One row of the `product_groups_resolved` view.
struct ResolvedProductGroup: Decodable, Sendable {
    var ancestorID: Int
    var descendantID: Int
    var depth: Int
    var path: String?

    enum CodingKeys: String, CodingKey {
        case ancestorID = "ancestor_product_group_id"
        case descendantID = "descendant_product_group_id"
        case depth
        case path
    }
}

extension ProductGroup {
    /// Builds the groups from the closure rows, sorted by path.
    ///
    /// A group's own path comes from its depth-0 row (the pair with itself);
    /// every row whose ancestor is the group names one of its members.
    static func groups(from rows: [ResolvedProductGroup]) -> [ProductGroup] {
        var paths: [Int: String] = [:]
        var members: [Int: Set<Int>] = [:]
        for row in rows {
            members[row.ancestorID, default: []].insert(row.descendantID)
            if row.depth == 0, let path = row.path, !path.isEmpty {
                paths[row.descendantID] = path
            }
        }
        return paths.map { id, path in
            ProductGroup(
                id: id,
                path: path,
                depth: path.components(separatedBy: " / ").count - 1,
                memberIDs: members[id] ?? [id]
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
