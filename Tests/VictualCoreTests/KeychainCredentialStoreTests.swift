import Foundation
import Security
import Testing

@testable import VictualCore

/// Whether this process can actually reach a Keychain.
///
/// A SwiftPM test binary on macOS is only ad-hoc signed, so the data-protection
/// Keychain refuses it (`errSecMissingEntitlement`). The file-based Keychain
/// normally works, but a locked or absent login Keychain on a CI machine will
/// refuse that too — and a test that cannot run should say so rather than fail.
enum KeychainAvailability {
    static let isAvailable: Bool = {
        let store = KeychainCredentialStore(
            configuration: .init(
                service: "dev.victual.victual-kit.availability-probe",
                usesDataProtectionKeychain: false
            )
        )
        let server = VictualServer(instanceURL: URL(string: "https://probe.invalid")!)
        do {
            try store.saveSynchronously("probe", for: server)
            defer { try? store.removeAllSynchronously() }
            return try store.apiKeySynchronously(for: server) == "probe"
        } catch {
            return false
        }
    }()
}

@Suite(
    "KeychainCredentialStore",
    .enabled(if: KeychainAvailability.isAvailable, "no usable Keychain in this process")
)
struct KeychainCredentialStoreTests {
    /// A store scoped to a service name unique to this run, so the tests can
    /// never see — or delete — anything belonging to the developer.
    private let store = KeychainCredentialStore(
        configuration: .init(
            service: "dev.victual.victual-kit.tests.\(UUID().uuidString)",
            usesDataProtectionKeychain: false
        )
    )

    private let server = VictualServer(instanceURL: URL(string: "https://victual.example.com")!)

    private func tearDown() {
        try? store.removeAllSynchronously()
    }

    @Test("Stores and reads back a key")
    func roundTripsAKey() async throws {
        defer { tearDown() }

        try await store.save("sk-victual-abc", for: server)

        #expect(try await store.apiKey(for: server) == "sk-victual-abc")
    }

    @Test("Reports no key for an instance it has never seen")
    func returnsNilWhenAbsent() async throws {
        defer { tearDown() }

        #expect(try await store.apiKey(for: server) == nil)
    }

    @Test("Replaces the key rather than keeping the stale one")
    func overwritesExistingKey() async throws {
        defer { tearDown() }

        try await store.save("first", for: server)
        try await store.save("second", for: server)

        #expect(try await store.apiKey(for: server) == "second")
        #expect(try await store.savedServers().count == 1)
    }

    @Test("Keeps instances apart")
    func isolatesInstances() async throws {
        defer { tearDown() }

        let other = VictualServer(instanceURL: URL(string: "https://work.example.com")!)
        try await store.save("home-key", for: server)
        try await store.save("work-key", for: other)

        #expect(try await store.apiKey(for: server) == "home-key")
        #expect(try await store.apiKey(for: other) == "work-key")
    }

    @Test("Forgetting one instance leaves the others alone")
    func removesOneInstance() async throws {
        defer { tearDown() }

        let other = VictualServer(instanceURL: URL(string: "https://work.example.com")!)
        try await store.save("home-key", for: server)
        try await store.save("work-key", for: other)

        try await store.removeAPIKey(for: server)

        #expect(try await store.apiKey(for: server) == nil)
        #expect(try await store.apiKey(for: other) == "work-key")
    }

    @Test("Forgetting an unknown instance is not an error")
    func removingAbsentKeySucceeds() async throws {
        defer { tearDown() }

        try await store.removeAPIKey(for: server)
    }

    @Test("Enumeration rebuilds the server, custom API prefix included")
    func enumeratesSavedServers() async throws {
        defer { tearDown() }

        let custom = VictualServer(
            instanceURL: URL(string: "https://example.com/victual")!,
            apiPathPrefix: "rest/api"
        )
        try await store.save("a", for: server)
        try await store.save("b", for: custom)

        let saved = try await store.savedServers()

        #expect(saved.count == 2)
        #expect(saved.contains(server))
        // The prefix round-trips through kSecAttrGeneric, so the rebuilt server
        // addresses the same base URL it was saved with.
        let rebuilt = try #require(saved.first { $0.instanceURL == custom.instanceURL })
        #expect(rebuilt.apiPathPrefix == "rest/api")
        #expect(rebuilt.baseURL.absoluteString == "https://example.com/victual/rest/api")
    }

    @Test("removeAll clears every key this store wrote")
    func clearsEverything() async throws {
        defer { tearDown() }

        try await store.save("a", for: server)
        try await store.save("b", for: VictualServer(instanceURL: URL(string: "https://b.test")!))

        try await store.removeAll()

        #expect(try await store.savedServers().isEmpty)
    }
}

@Suite("InMemoryCredentialStore")
struct InMemoryCredentialStoreTests {
    private let server = VictualServer(instanceURL: URL(string: "https://victual.example.com")!)

    @Test("Behaves like the Keychain store, without the Keychain")
    func roundTrips() async throws {
        let store = InMemoryCredentialStore()

        #expect(try await store.apiKey(for: server) == nil)

        try await store.save("key", for: server)
        #expect(try await store.apiKey(for: server) == "key")
        #expect(try await store.savedServers() == [server])

        try await store.removeAPIKey(for: server)
        #expect(try await store.apiKey(for: server) == nil)
        #expect(try await store.savedServers().isEmpty)
    }

    @Test("Can be seeded for previews")
    func acceptsInitialContents() async throws {
        let store = InMemoryCredentialStore([server: "seeded"])
        #expect(try await store.apiKey(for: server) == "seeded")
    }
}
