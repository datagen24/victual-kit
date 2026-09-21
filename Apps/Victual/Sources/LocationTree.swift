import Foundation
import VictualCore

/// One node of the sidebar's locations tree.
///
/// The server reports locations flat, with a parent id each and a display path
/// from `locations_resolved`. Nesting them is presentation, so it happens here
/// rather than in the package.
struct LocationNode: Identifiable, Hashable {
    let location: StorageLocation
    var children: [LocationNode]?

    var id: Int { location.id }
    var name: String { location.displayName }

    /// Builds the forest, roots first, each level ordered by name.
    ///
    /// A location whose parent is not in the list — because it was deleted, or
    /// because the caller may not see it — is treated as a root rather than
    /// dropped. Losing a location that holds stock would be worse than showing
    /// it one level too high.
    static func forest(from locations: [StorageLocation]) -> [LocationNode] {
        let known = Set(locations.map(\.id))
        var childrenByParent: [Int: [StorageLocation]] = [:]
        var roots: [StorageLocation] = []

        for location in locations {
            if let parent = location.parentID, known.contains(parent), parent != location.id {
                childrenByParent[parent, default: []].append(location)
            } else {
                roots.append(location)
            }
        }

        func build(_ location: StorageLocation, depth: Int) -> LocationNode {
            // The schema caps the tree at six levels; the guard is against a
            // cycle in the data, not against depth as such.
            let children = depth >= 8 ? [] : (childrenByParent[location.id] ?? [])
            let built =
                children
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                .map { build($0, depth: depth + 1) }
            return LocationNode(location: location, children: built.isEmpty ? nil : built)
        }

        return roots
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { build($0, depth: 0) }
    }
}
