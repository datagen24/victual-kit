import Foundation
import Testing

@testable import VictualCore

@Suite("VictualServer")
struct VictualServerTests {
    @Test(
        "Accepts the shapes people type into a connection field",
        arguments: [
            ("victual.example.com", "https://victual.example.com/api"),
            ("https://victual.example.com", "https://victual.example.com/api"),
            ("https://victual.example.com/", "https://victual.example.com/api"),
            ("  https://victual.example.com  ", "https://victual.example.com/api"),
            ("http://victual.local:9283", "http://victual.local:9283/api"),
            ("https://example.com/victual", "https://example.com/victual/api"),
        ]
    )
    func parsesUserInput(input: String, expected: String) throws {
        let server = try VictualServer(userEnteredText: input)
        #expect(server.baseURL.absoluteString == expected)
    }

    @Test("Folds a typed-out /api suffix instead of doubling it")
    func doesNotDoubleAPIPrefix() throws {
        let server = try VictualServer(userEnteredText: "https://victual.example.com/api")
        #expect(server.baseURL.absoluteString == "https://victual.example.com/api")
        #expect(server.instanceURL.absoluteString == "https://victual.example.com")
    }

    @Test(
        "Rejects input that is not an http(s) address",
        arguments: ["", "   ", "ftp://victual.example.com", "https://", "not a url at all"]
    )
    func rejectsInvalidInput(input: String) {
        #expect(throws: VictualError.self) {
            try VictualServer(userEnteredText: input)
        }
    }

    @Test("The base URL never ends in a slash")
    func baseURLHasNoTrailingSlash() {
        // The transport appends the operation path textually, so a trailing
        // slash here would send every request to `//system/info`.
        let server = VictualServer(instanceURL: URL(string: "https://victual.example.com/")!)
        #expect(server.baseURL.absoluteString == "https://victual.example.com/api")
    }

    @Test("An empty API prefix leaves the instance URL alone")
    func honoursEmptyPrefix() {
        let server = VictualServer(
            instanceURL: URL(string: "https://victual.example.com")!,
            apiPathPrefix: ""
        )
        #expect(server.baseURL.absoluteString == "https://victual.example.com")
    }

    @Test("Keeps a sub-path when Victual is not at the domain root")
    func keepsSubPath() throws {
        let server = try VictualServer(userEnteredText: "https://example.com/victual")
        #expect(server.baseURL.absoluteString == "https://example.com/victual/api")
    }

    @Test("Round-trips through Codable")
    func isCodable() throws {
        let server = try VictualServer(userEnteredText: "victual.example.com")
        let data = try JSONEncoder().encode(server)
        #expect(try JSONDecoder().decode(VictualServer.self, from: data) == server)
    }
}
