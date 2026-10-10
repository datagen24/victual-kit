import CryptoKit
import Foundation

/// How a Health medication becomes the server's opaque `medication_ref`.
///
/// `HKHealthConceptIdentifier` is an opaque `NSSecureCoding` object with no
/// documented string form, and ADR-0041 wants `^[A-Za-z0-9._:-]{1,128}$`. This
/// is the one function that decides, so the choice is made in one place and the
/// device spike can show both candidates side by side.
///
/// Neither candidate is proven stable across launches yet; the spike records
/// that. If the hash turns out unstable the plan's fallback (a locally assigned
/// UUID stored with the mapping) replaces it.
public enum MedicationRef {
    /// Prefix of the hashed form, ADR-0041's own example (`hk:med:42`).
    public static let hashedPrefix = "hk:med:"

    /// Whether `text` fits the server's `medication_ref` pattern.
    public static func isValid(_ text: String) -> Bool {
        guard (1...128).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"),
                UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: ":"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    /// `hk:med:` followed by the lowercase hex SHA-256 of the identifier's
    /// secure-coded archive.
    public static func hashed(archive: Data) -> String {
        hashedPrefix + SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    }

    /// The reference to use: the identifier's `description` if it fits the
    /// pattern, else the hash of its archive.
    ///
    /// The default `NSObject` description (`<Class: 0x…>`) fails the pattern, so
    /// a pointer-based string can never be chosen by accident.
    public static func choose(description: String?, archive: Data) -> String {
        if let description, isValid(description) { return description }
        return hashed(archive: archive)
    }

    /// Both candidates for one identifier, as the device spike records them.
    public struct Candidates: Sendable, Equatable {
        /// The identifier's `description`, whatever it is.
        public var description: String?
        public var descriptionIsValid: Bool
        public var hashed: String
        /// What ``choose(description:archive:)`` picks.
        public var chosen: String
    }

    /// Both candidates for an identifier whose archive is `archive`.
    public static func candidates(description: String?, archive: Data) -> Candidates {
        Candidates(
            description: description,
            descriptionIsValid: description.map(isValid) ?? false,
            hashed: hashed(archive: archive),
            chosen: choose(description: description, archive: archive))
    }
}
