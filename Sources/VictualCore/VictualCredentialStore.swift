import Foundation

/// Persistence for the API keys of the Victual instances someone has signed
/// into.
///
/// A store is keyed by ``VictualServer``, so an app can hold keys for several
/// instances at once — a home server and a work one, say — and switch between
/// them without re-entering either.
///
/// The methods are `async` so a store can be backed by something slower than
/// the Keychain later. ``KeychainCredentialStore`` satisfies them synchronously.
public protocol VictualCredentialStore: Sendable {
    /// The stored key for `server`, or `nil` if there is none.
    func apiKey(for server: VictualServer) async throws -> VictualAPIKey?

    /// Stores `apiKey` for `server`, replacing any key already held for it.
    func save(_ apiKey: VictualAPIKey, for server: VictualServer) async throws

    /// Forgets the key for `server`. Succeeds when there was nothing to forget.
    func removeAPIKey(for server: VictualServer) async throws

    /// Every instance the store holds a key for.
    func savedServers() async throws -> [VictualServer]
}

/// Why a credential store could not do what was asked.
public enum VictualCredentialStoreError: Error, Hashable, Sendable {
    /// The Keychain refused the operation. `status` is the `OSStatus` it
    /// returned; `operation` names what was being attempted.
    case keychain(status: OSStatus, operation: String)

    /// An item was found but its contents were not a key this package wrote.
    case malformedStoredValue

    /// A store other than ``KeychainCredentialStore`` failed. Carries the
    /// error's description, so the case stays `Hashable` and `Sendable`.
    case underlying(description: String)

    /// Wraps an arbitrary error thrown by a custom store.
    public init(_ error: any Error) {
        if let known = error as? VictualCredentialStoreError {
            self = known
        } else {
            self = .underlying(description: error.localizedDescription)
        }
    }
}

extension VictualCredentialStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keychain(let status, let operation):
            let detail =
                SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "OSStatus \(status)"
            return "Could not \(operation) the saved API key: \(detail)"
        case .malformedStoredValue:
            return "The saved API key could not be read and should be entered again."
        case .underlying(let description):
            return "Could not reach the saved API key: \(description)"
        }
    }
}

/// A credential store that keeps everything in memory.
///
/// Intended for SwiftUI previews and for tests that should not touch the user's
/// Keychain. It is a complete implementation, not a stub — it just does not
/// outlive the process.
public final class InMemoryCredentialStore: VictualCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VictualServer: VictualAPIKey]

    public init(_ initial: [VictualServer: VictualAPIKey] = [:]) {
        self.storage = initial
    }

    public func apiKey(for server: VictualServer) async throws -> VictualAPIKey? {
        lock.withLock { storage[server] }
    }

    public func save(_ apiKey: VictualAPIKey, for server: VictualServer) async throws {
        lock.withLock { storage[server] = apiKey }
    }

    public func removeAPIKey(for server: VictualServer) async throws {
        lock.withLock { storage[server] = nil }
    }

    public func savedServers() async throws -> [VictualServer] {
        lock.withLock { Array(storage.keys) }
            .sorted { $0.baseURL.absoluteString < $1.baseURL.absoluteString }
    }
}
