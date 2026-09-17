import Foundation
import Testing
import VictualCore
import VictualTestSupport

@testable import VictualUI

@Suite("VictualSession")
@MainActor
struct VictualSessionTests {
    /// Defaults scoped to this test run, so nothing touches the developer's own
    /// `UserDefaults` and no two tests can see each other's remembered instance.
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "victual-kit.tests.\(UUID().uuidString)")!
    }

    private func session(
        serverText: String = "victual.example.com",
        apiKeyText: String = "test-key",
        transport: StubTransport,
        credentialStore: any VictualCredentialStore = InMemoryCredentialStore(),
        defaults: UserDefaults? = nil
    ) -> VictualSession {
        VictualSession(
            serverText: serverText,
            apiKeyText: apiKeyText,
            credentialStore: credentialStore,
            defaults: defaults ?? isolatedDefaults()
        ) { server, key in
            VictualClient(server: server, apiKey: key, transport: transport)
        }
    }

    @Test("Starts disconnected")
    func startsDisconnected() {
        let session = session(transport: StubTransport(status: 200, json: systemInfoJSON))
        #expect(!session.state.isConnected)
        #expect(session.client == nil)
    }

    @Test("Connecting stores the client and the instance details")
    func connectsSuccessfully() async {
        let session = session(transport: StubTransport(status: 200, json: systemInfoJSON))

        session.connect()
        await session.waitForConnectionAttempt()

        guard case .connected(let information) = session.state else {
            Issue.record("expected .connected, got \(session.state)")
            return
        }
        #expect(information.victualVersion == "4.2.0")
        #expect(session.client != nil)
    }

    @Test("A rejected key leaves the session failed and without a client")
    func surfacesAuthenticationFailure() async {
        let session = session(
            transport: StubTransport(status: 401, json: #"{"error_message":"nope"}"#)
        )

        session.connect()
        await session.waitForConnectionAttempt()

        #expect(session.state.error == .unauthorized)
        #expect(session.client == nil)
    }

    @Test("An unparseable address fails without a round trip")
    func rejectsBadAddressLocally() async {
        let transport = StubTransport(status: 200, json: systemInfoJSON)
        let session = session(serverText: "ftp://nope", transport: transport)

        session.connect()
        await session.waitForConnectionAttempt()

        #expect(session.state.error != nil)
        #expect(transport.recorder.requests.isEmpty)
    }

    @Test("canConnect gates on both fields being filled in")
    func gatesTheConnectButton() {
        let transport = StubTransport(status: 200, json: systemInfoJSON)

        #expect(session(transport: transport).canConnect)
        #expect(!session(serverText: "  ", transport: transport).canConnect)
        #expect(!session(apiKeyText: "", transport: transport).canConnect)
    }

    @Test("Disconnecting drops the client but keeps what was typed")
    func disconnectKeepsCredentials() async {
        let session = session(transport: StubTransport(status: 200, json: systemInfoJSON))
        session.connect()
        await session.waitForConnectionAttempt()

        session.disconnect()

        #expect(session.client == nil)
        #expect(!session.state.isConnected)
        #expect(session.serverText == "victual.example.com")
        #expect(session.apiKeyText == "test-key")
    }
}

@Suite("VictualSession credential persistence")
@MainActor
struct VictualSessionCredentialTests {
    private let server = try! VictualServer(userEnteredText: "victual.example.com")

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "victual-kit.tests.\(UUID().uuidString)")!
    }

    private func session(
        serverText: String = "victual.example.com",
        apiKeyText: String = "test-key",
        transport: StubTransport,
        store: any VictualCredentialStore,
        defaults: UserDefaults
    ) -> VictualSession {
        VictualSession(
            serverText: serverText,
            apiKeyText: apiKeyText,
            credentialStore: store,
            defaults: defaults
        ) { server, key in
            VictualClient(server: server, apiKey: key, transport: transport)
        }
    }

    @Test("A successful connection saves the key and remembers the instance")
    func persistsOnConnect() async throws {
        let store = InMemoryCredentialStore()
        let defaults = defaults()
        let session = session(
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: store,
            defaults: defaults
        )

        session.connect()
        await session.waitForConnectionAttempt()

        #expect(try await store.apiKey(for: server) == "test-key")
        #expect(session.lastUsedServer == server)
        #expect(session.credentialStoreError == nil)
    }

    @Test("A failed connection saves nothing")
    func doesNotPersistOnFailure() async throws {
        let store = InMemoryCredentialStore()
        let defaults = defaults()
        let session = session(
            transport: StubTransport(status: 401, json: #"{"error_message":"nope"}"#),
            store: store,
            defaults: defaults
        )

        session.connect()
        await session.waitForConnectionAttempt()

        #expect(try await store.apiKey(for: server) == nil)
        #expect(session.lastUsedServer == nil)
    }

    @Test("restore() reconnects from what was saved")
    func restoresSavedCredentials() async throws {
        let store = InMemoryCredentialStore()
        let defaults = defaults()

        // First launch: sign in.
        let first = session(
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: store,
            defaults: defaults
        )
        first.connect()
        await first.waitForConnectionAttempt()

        // Second launch: nothing typed, same store and defaults.
        let second = session(
            serverText: "",
            apiKeyText: "",
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: store,
            defaults: defaults
        )

        let restored = await second.restore()

        #expect(restored)
        #expect(second.state.isConnected)
        #expect(second.apiKeyText == "test-key")
        #expect(second.serverText == "https://victual.example.com")
    }

    @Test("restore() reports false when nothing was remembered")
    func restoreWithoutSavedCredentials() async {
        let session = session(
            serverText: "",
            apiKeyText: "",
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: InMemoryCredentialStore(),
            defaults: defaults()
        )

        let restored = await session.restore()

        #expect(!restored)
        #expect(!session.state.isConnected)
    }

    @Test("restore() reports false when the instance is remembered but the key is gone")
    func restoreWithMissingKey() async throws {
        let store = InMemoryCredentialStore()
        let defaults = defaults()
        let session = session(
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: store,
            defaults: defaults
        )
        session.connect()
        await session.waitForConnectionAttempt()

        try await store.removeAPIKey(for: server)
        session.disconnect()

        #expect(await session.restore() == false)
    }

    @Test("signOut() forgets the key and the instance but keeps the address")
    func signOutForgetsCredentials() async throws {
        let store = InMemoryCredentialStore()
        let defaults = defaults()
        let session = session(
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: store,
            defaults: defaults
        )
        session.connect()
        await session.waitForConnectionAttempt()

        await session.signOut()

        #expect(try await store.apiKey(for: server) == nil)
        #expect(session.lastUsedServer == nil)
        #expect(session.apiKeyText.isEmpty)
        #expect(session.serverText == "victual.example.com")
        #expect(!session.state.isConnected)
    }

    @Test("disconnect() keeps the saved key so the next launch can restore")
    func disconnectKeepsSavedKey() async throws {
        let store = InMemoryCredentialStore()
        let defaults = defaults()
        let session = session(
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: store,
            defaults: defaults
        )
        session.connect()
        await session.waitForConnectionAttempt()

        session.disconnect()

        #expect(try await store.apiKey(for: server) == "test-key")
        #expect(session.lastUsedServer == server)
    }

    @Test("A store that cannot save is reported without breaking the connection")
    func surfacesCredentialStoreFailure() async throws {
        let session = session(
            transport: StubTransport(status: 200, json: systemInfoJSON),
            store: FailingCredentialStore(),
            defaults: defaults()
        )

        session.connect()
        await session.waitForConnectionAttempt()

        #expect(session.state.isConnected)
        #expect(session.client != nil)
        #expect(session.credentialStoreError != nil)
    }
}

/// A store whose every operation fails, to prove a broken Keychain degrades to
/// "you will have to type the key again" rather than "you cannot sign in".
private struct FailingCredentialStore: VictualCredentialStore {
    struct Failure: Error {}

    func apiKey(for server: VictualServer) async throws -> VictualAPIKey? { throw Failure() }
    func save(_ apiKey: VictualAPIKey, for server: VictualServer) async throws { throw Failure() }
    func removeAPIKey(for server: VictualServer) async throws { throw Failure() }
    func savedServers() async throws -> [VictualServer] { throw Failure() }
}
