import Foundation
import Testing

@testable import VictualCore

@Suite("Server version")
struct ServerVersionTests {
    @Test("Release numbers order numerically, ignoring a stage suffix", arguments: [
        ("0.2.0-MVP", "0.3.0"), ("0.3.0", "0.3.1"), ("0.9.0", "0.10.0"), ("0.3", "0.3.1"),
        ("v0.3.0", "1.0.0"),
    ])
    func ordering(older: String, newer: String) throws {
        #expect(try #require(ServerVersion(older)) < #require(ServerVersion(newer)))
    }

    @Test("Trailing zeros and a stage suffix do not make versions differ")
    func equality() {
        #expect(ServerVersion("0.3") == ServerVersion("0.3.0"))
        #expect(ServerVersion("0.2.0-MVP") == ServerVersion("0.2.0"))
    }

    @Test("Text without a leading number is not a version", arguments: [nil, "", "dev", "-1"] as [String?])
    func unreadable(text: String?) {
        #expect(ServerVersion(text) == nil)
    }

    @Test("Only a newer server warns", arguments: [
        ("0.3.2", false), ("0.3.0", false), ("0.2.0-MVP", false), ("0.3.3", true), ("0.4.0", true),
        ("1.0.0", true), (nil, false), ("dev", false),
    ] as [(String?, Bool)])
    func warning(reported: String?, warns: Bool) {
        let info = SystemInformation(victualVersion: reported)
        #expect(info.isNewerThanSupported == warns)
        #expect((info.versionWarning != nil) == warns)
    }

    @Test("The supported version is the vendored specification's version")
    func matchesSpecification() throws {
        let spec = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VictualAPI/openapi.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: spec)) as? [String: Any]
        let info = try #require(object?["info"] as? [String: Any])
        let version = try #require(info["version"] as? String)
        #expect(ServerVersion(version) == VictualClient.supportedServerVersion)
    }
}
