import CryptoKit
import Foundation

/// How the mapping chooses the organizer, ADR-0041 rule 4.
public struct MappingLocation: Sendable, Equatable, Codable {
    public enum Mode: String, CaseIterable, Sendable, Codable {
        case fixed
        case single
        case explicit
    }

    public var mode: Mode
    public var locationID: Int?

    public init(mode: Mode, locationID: Int? = nil) {
        self.mode = mode
        self.locationID = locationID
    }
}

/// The person's approved mapping from one medication to a product or recipe.
///
/// The server holds the authoritative copy; this is what the device needs to
/// filter and shape events. The client never guesses any of it.
public struct Mapping: Sendable, Equatable, Codable {
    public enum Target: Sendable, Equatable, Codable {
        case product(Int)
        case recipe(Int)
    }

    public var medicationRef: String
    public var target: Target
    public var location: MappingLocation
    /// Events that started earlier are not read and not sent.
    public var effectiveFrom: Date

    public init(
        medicationRef: String,
        target: Target,
        location: MappingLocation,
        effectiveFrom: Date
    ) {
        self.medicationRef = medicationRef
        self.target = target
        self.location = location
        self.effectiveFrom = effectiveFrom
    }
}

/// The mappings a sync runs under.
///
/// Its ``id`` is part of the anchor key: changing what is mapped, where it
/// books, or from when, must restart the read at `effectiveFrom` rather than
/// resume an anchor that skipped those events. Edits that do not change which
/// events are read or where they book (a unit label, a default quantity) are
/// not part of ``Mapping`` and so do not move the id.
public struct MappingSet: Sendable, Equatable {
    public private(set) var mappings: [String: Mapping]

    public init(_ mappings: [Mapping] = []) {
        self.mappings = Dictionary(mappings.map { ($0.medicationRef, $0) }) { _, last in last }
    }

    public subscript(medicationRef: String) -> Mapping? { mappings[medicationRef] }

    /// A stable digest of the mappings that decide what is read and where it books.
    public var id: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = mappings.keys.sorted().compactMap { key in
            mappings[key].flatMap { try? encoder.encode($0) }
        }
        var hash = SHA256()
        for chunk in bytes { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
