import Foundation

/// A Victual release number, compared the way releases are ordered.
///
/// The server reports it as text in `GET /system/info`: `"0.3.0"`, or before
/// 0.3.0 `"0.2.0-MVP"`. Only the leading dotted numbers order releases; a suffix
/// after them is a release stage and is ignored.
public struct ServerVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Reads `"0.3.0"`, `"0.2.0-MVP"` or `"v0.3.0"`; `nil` when no leading number is found.
    public init?(_ text: String?) {
        guard var text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let numeric = text.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

extension VictualClient {
    /// The Victual release this package was generated from and tested against.
    ///
    /// A test keeps it equal to the vendored specification's `info.version`, so a
    /// spec sync cannot move one without the other.
    public static let supportedServerVersion = ServerVersion("0.3.2")!
}

extension SystemInformation {
    /// Whether the instance runs a release newer than this package knows.
    ///
    /// A newer server may send shapes the package cannot read — a label on a kind
    /// of thing added since, for one — so callers show a warning rather than
    /// refusing to connect. `false` when the server reports no version, or one
    /// that cannot be read: nothing is known, so nothing is claimed.
    public var isNewerThanSupported: Bool {
        guard let reported = ServerVersion(victualVersion) else { return false }
        return reported > VictualClient.supportedServerVersion
    }

    /// A sentence for the user when ``isNewerThanSupported``, otherwise `nil`.
    public var versionWarning: String? {
        guard isNewerThanSupported, let reported = victualVersion else { return nil }
        return "This server runs Victual \(reported), newer than this app was built for "
            + "(\(VictualClient.supportedServerVersion)). Some things may not work as expected; "
            + "update the app."
    }
}
