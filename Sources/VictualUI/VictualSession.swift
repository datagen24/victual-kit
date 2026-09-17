import Foundation
import Observation
import VictualCore

/// The connection a SwiftUI app holds for the lifetime of a window or scene.
///
/// A session owns the instance address, the API key, and the state of the last
/// connection attempt. Views observe it; they do not build clients themselves.
/// It is main-actor isolated because every property it publishes drives UI.
///
/// The API key is persisted through a ``VictualCredentialStore`` — the Keychain
/// by default — so a returning user does not retype it. Call ``restore()`` at
/// launch; a successful ``connect()`` saves; ``signOut()`` forgets.
@MainActor
@Observable
public final class VictualSession {
    /// Where a session is in its connection lifecycle.
    public enum State: Sendable {
        /// No connection has been attempted, or the session was signed out.
        case disconnected
        /// A connection attempt is in flight.
        case connecting
        /// The server answered and accepted the API key.
        case connected(SystemInformation)
        /// The last attempt failed. The session keeps the entered credentials so
        /// the user can correct them.
        case failed(VictualError)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        public var isConnecting: Bool {
            if case .connecting = self { return true }
            return false
        }

        public var error: VictualError? {
            if case .failed(let error) = self { return error }
            return nil
        }
    }

    /// The `UserDefaults` key holding the instance a session last connected to.
    ///
    /// Only the address lives here — never the API key, which is the credential
    /// store's job.
    public static let lastServerDefaultsKey = "dev.victual.victual-kit.last-server"

    /// The instance address as typed by the user. Parsed on ``connect()``.
    public var serverText: String

    /// The API key as typed by the user.
    public var apiKeyText: String

    public private(set) var state: State = .disconnected

    /// The authenticated client, available once ``state`` is `.connected`.
    public private(set) var client: VictualClient?

    /// The most recent credential-store failure, if any.
    ///
    /// Kept apart from ``state`` because it is not fatal: a session whose key
    /// could not be saved is still connected and usable, the user will just be
    /// asked for the key again next launch.
    public private(set) var credentialStoreError: VictualCredentialStoreError?

    private let credentialStore: any VictualCredentialStore
    private let defaults: UserDefaults
    private let makeClient: @Sendable (VictualServer, VictualAPIKey) -> VictualClient
    private var attempt: Task<Void, Never>?

    /// Creates a session.
    ///
    /// - Parameters:
    ///   - credentialStore: Where the API key is kept between launches. The
    ///     default is the Keychain; pass `InMemoryCredentialStore()` in previews.
    ///   - defaults: Where the last-used instance address is remembered.
    ///   - clientFactory: How to build a client once the address and key parse.
    ///     The default uses `URLSession`; tests pass a factory backed by a stub
    ///     transport.
    public init(
        serverText: String = "",
        apiKeyText: String = "",
        credentialStore: any VictualCredentialStore = KeychainCredentialStore(),
        defaults: UserDefaults = .standard,
        clientFactory: @escaping @Sendable (VictualServer, VictualAPIKey) -> VictualClient = {
            VictualClient(server: $0, apiKey: $1)
        }
    ) {
        self.serverText = serverText
        self.apiKeyText = apiKeyText
        self.credentialStore = credentialStore
        self.defaults = defaults
        self.makeClient = clientFactory
    }

    /// Whether the entered values are complete enough to be worth a round trip.
    public var canConnect: Bool {
        !serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && VictualAPIKey(apiKeyText).isWellFormed
            && !state.isConnecting
    }

    /// The instance a session last connected to, if one was remembered.
    public var lastUsedServer: VictualServer? {
        guard let data = defaults.data(forKey: Self.lastServerDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(VictualServer.self, from: data)
    }

    // MARK: - Connecting

    /// Validates the entered address and key against the server, and saves them
    /// on success.
    ///
    /// Supersedes any attempt already in flight, so repeated taps cannot leave
    /// the session showing the result of an older attempt.
    public func connect() {
        attempt?.cancel()
        attempt = Task { [weak self] in
            guard let self else { return }
            await self.performConnect()
        }
    }

    /// Awaits the in-flight connection attempt, if there is one.
    public func waitForConnectionAttempt() async {
        await attempt?.value
    }

    /// Reconnects using the remembered instance and its saved key.
    ///
    /// Call this once at launch. It returns `false` — without changing
    /// ``state`` — when there is nothing remembered, which is the signal to show
    /// ``VictualConnectionView``.
    ///
    /// - Returns: Whether the session ended up connected.
    @discardableResult
    public func restore() async -> Bool {
        guard let server = lastUsedServer else { return false }

        let saved: VictualAPIKey?
        do {
            saved = try await credentialStore.apiKey(for: server)
        } catch {
            credentialStoreError = VictualCredentialStoreError(error)
            return false
        }
        guard let saved, saved.isWellFormed else { return false }

        serverText = server.instanceURL.absoluteString
        apiKeyText = saved.rawValue
        connect()
        await waitForConnectionAttempt()
        return state.isConnected
    }

    /// Drops the client and returns to `.disconnected`, leaving the entered
    /// address and key — and anything saved — in place.
    public func disconnect() {
        attempt?.cancel()
        attempt = nil
        client = nil
        state = .disconnected
    }

    /// Disconnects and forgets the instance: its key is removed from the
    /// credential store and it is no longer the remembered instance.
    ///
    /// The address is kept in ``serverText`` so signing back in only needs a new
    /// key.
    public func signOut() async {
        attempt?.cancel()
        attempt = nil

        if let server = try? VictualServer(userEnteredText: serverText) {
            do {
                try await credentialStore.removeAPIKey(for: server)
                credentialStoreError = nil
            } catch {
                credentialStoreError = VictualCredentialStoreError(error)
            }
        }

        defaults.removeObject(forKey: Self.lastServerDefaultsKey)
        client = nil
        apiKeyText = ""
        state = .disconnected
    }

    // MARK: - Implementation

    private func performConnect() async {
        state = .connecting

        let server: VictualServer
        do {
            server = try VictualServer(userEnteredText: serverText)
        } catch {
            client = nil
            state = .failed(VictualError.mapping(error))
            return
        }

        let key = VictualAPIKey(apiKeyText)
        let candidate = makeClient(server, key)
        do {
            let information = try await candidate.verifyConnection()
            guard !Task.isCancelled else { return }
            client = candidate
            state = .connected(information)
            await remember(key, for: server)
        } catch {
            guard !Task.isCancelled else { return }
            client = nil
            state = .failed(error)
        }
    }

    /// Saves the key and marks the instance as the one to restore next launch.
    ///
    /// A failure here is recorded on ``credentialStoreError`` but does not
    /// disturb ``state``: the session is connected either way.
    private func remember(_ key: VictualAPIKey, for server: VictualServer) async {
        do {
            try await credentialStore.save(key, for: server)
            credentialStoreError = nil
        } catch {
            credentialStoreError = VictualCredentialStoreError(error)
            return
        }

        if let data = try? JSONEncoder().encode(server) {
            defaults.set(data, forKey: Self.lastServerDefaultsKey)
        }
    }
}
