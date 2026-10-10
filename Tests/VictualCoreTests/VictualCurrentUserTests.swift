import Foundation
import Testing
import VictualTestSupport

@testable import VictualCore

@Suite("Current user")
struct CurrentUserTests {
    @Test("The id is read from the one-element array GET /user returns")
    func readsTheId() async throws {
        let client = VictualClient.stubbed(
            StubTransport(status: 200, json: #"[{"id": 12, "username": "x", "display_name": "X"}]"#))
        #expect(try await client.currentUserID() == 12)
    }

    @Test("An empty answer is not a user")
    func emptyIsNotFound() async {
        let client = VictualClient.stubbed(StubTransport(status: 200, json: "[]"))
        await #expect(throws: VictualError.notFound) { try await client.currentUserID() }
    }

    @Test("A rejected key is unauthorized")
    func rejectedKey() async {
        let client = VictualClient.stubbed(StubTransport(status: 401, json: "{}"))
        await #expect(throws: VictualError.unauthorized) { try await client.currentUserID() }
    }
}
