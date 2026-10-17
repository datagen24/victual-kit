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
        let client = VictualClient.stubbed(StubTransport(status: 401, json: #"{"error_message":"Unauthorized"}"#))
        await #expect(throws: VictualError.unauthorized) { try await client.currentUserID() }
    }

    /// A 401 a reverse proxy answers has no `error_message` body, which the
    /// 0.4.4 document declares; the status still decides the case.
    @Test("A rejected key without the documented body is still unauthorized")
    func rejectedKeyWithoutBody() async {
        let client = VictualClient.stubbed(StubTransport(status: 401, json: ""))
        await #expect(throws: VictualError.unauthorized) { try await client.currentUserID() }
    }
}
