import Foundation
import Security

/// Stores Victual API keys, and Cloudflare Access service tokens, in the
/// Keychain.
///
/// Each instance gets one generic-password item for its API key:
///
/// - `kSecAttrService` — ``Configuration/service``, shared by every item this
///   store writes, so they can be enumerated and cleared together.
/// - `kSecAttrAccount` — the instance URL, which is what shows in Keychain
///   Access and makes an item recognisable to the person who owns it.
/// - `kSecAttrGeneric` — the API path prefix, so a ``VictualServer`` can be
///   rebuilt exactly rather than guessed at.
/// - the value — the API key, UTF-8 encoded.
///
/// An instance behind Cloudflare Access gets a second item for its service
/// token, under ``Configuration/edgeTokenService`` with the same account. The
/// value is the token's Client ID and Secret as JSON, so the pair is written
/// and replaced together. A separate service keeps API-key items exactly as
/// they were, with nothing to migrate.
///
/// The Keychain calls are synchronous. A single-item lookup is fast enough that
/// the main actor will not notice, which is why ``VictualCredentialStore``'s
/// `async` requirements are satisfied without hopping off it.
public struct KeychainCredentialStore: VictualCredentialStore {
    /// How items are written and who can read them back.
    public struct Configuration: Sendable, Hashable {
        /// The `kSecAttrService` every item shares.
        ///
        /// Change it to keep two apps' keys apart in the same access group.
        public var service: String

        /// The `kSecAttrService` of the items holding Cloudflare Access service
        /// tokens. Same account, same access group and same accessibility as
        /// the API key it sits beside.
        ///
        /// Defaults to ``service`` with `.edge-token` appended, so two stores
        /// with different services never share tokens — or clear each other's
        /// in ``KeychainCredentialStore/removeAll()``.
        public var edgeTokenService: String

        /// A Keychain access group, so an app extension or widget can read the
        /// same keys. `nil` uses the app's default group.
        ///
        /// Requires the `keychain-access-groups` entitlement.
        public var accessGroup: String?

        /// When the item can be read.
        public var accessibility: Accessibility

        /// Whether to sync the key to the user's other devices through iCloud
        /// Keychain.
        ///
        /// Off by default: it is the user's call whether a server credential
        /// leaves the device. Turning it on requires an ``accessibility`` that
        /// is not `ThisDeviceOnly`, or the Keychain rejects the item with
        /// `errSecParam`.
        public var synchronizesWithiCloud: Bool

        /// Whether to use the data-protection Keychain, which is the modern
        /// behaviour and the only one on iOS.
        ///
        /// On macOS it requires a signed binary with a Keychain access group,
        /// which an app bundle has and a bare command-line or test binary does
        /// not — set it to `false` there, and items go to the older file-based
        /// Keychain instead.
        public var usesDataProtectionKeychain: Bool

        public init(
            service: String = "dev.victual.victual-kit.api-key",
            edgeTokenService: String? = nil,
            accessGroup: String? = nil,
            accessibility: Accessibility = .afterFirstUnlock,
            synchronizesWithiCloud: Bool = false,
            usesDataProtectionKeychain: Bool = true
        ) {
            self.service = service
            self.edgeTokenService = edgeTokenService ?? service + ".edge-token"
            self.accessGroup = accessGroup
            self.accessibility = accessibility
            self.synchronizesWithiCloud = synchronizesWithiCloud
            self.usesDataProtectionKeychain = usesDataProtectionKeychain
        }
    }

    /// When a stored key can be read back.
    public enum Accessibility: Sendable, Hashable {
        /// Only while the device is unlocked.
        case whenUnlocked
        /// After the first unlock following a restart. Lets a background
        /// refresh reach the server without the user present.
        case afterFirstUnlock
        /// As ``whenUnlocked``, but never restored to another device.
        case whenUnlockedThisDeviceOnly
        /// As ``afterFirstUnlock``, but never restored to another device.
        case afterFirstUnlockThisDeviceOnly

        var rawValue: CFString {
            switch self {
            case .whenUnlocked: return kSecAttrAccessibleWhenUnlocked
            case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlock
            case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - VictualCredentialStore

    // Every one of these hops off the caller's actor before touching the
    // Security framework.
    //
    // `SecItemCopyMatching` and friends are synchronous and can block for a
    // long time: the Keychain may put an authorisation dialog in front of the
    // user, and a change of code signature is enough to provoke one. Satisfying
    // an `async` requirement with a synchronous body runs that call on whatever
    // actor asked — which, for a SwiftUI app calling `VictualSession.restore()`
    // at launch, is the main actor.
    //
    // Observed rather than theorised: it froze the main thread before the first
    // window was drawn, so the application came up windowless and looked hung
    // while a dialog waited behind it.
    //
    // The `…Synchronously` variants remain public for a caller that is already
    // off the main actor and wants no hop.

    public func apiKey(for server: VictualServer) async throws -> VictualAPIKey? {
        try await offCallerActor { try self.apiKeySynchronously(for: server) }
    }

    public func save(_ apiKey: VictualAPIKey, for server: VictualServer) async throws {
        try await offCallerActor { try self.saveSynchronously(apiKey, for: server) }
    }

    public func removeAPIKey(for server: VictualServer) async throws {
        try await offCallerActor { try self.removeAPIKeySynchronously(for: server) }
    }

    public func savedServers() async throws -> [VictualServer] {
        try await offCallerActor { try self.savedServersSynchronously() }
    }

    public func edgeCredential(for server: VictualServer) async throws -> VictualEdgeCredential? {
        try await offCallerActor { try self.edgeCredentialSynchronously(for: server) }
    }

    public func save(_ edgeCredential: VictualEdgeCredential, for server: VictualServer) async throws {
        try await offCallerActor { try self.saveSynchronously(edgeCredential, for: server) }
    }

    public func removeEdgeCredential(for server: VictualServer) async throws {
        try await offCallerActor { try self.removeEdgeCredentialSynchronously(for: server) }
    }

    /// Removes every key and token this store wrote.
    public func removeAll() async throws {
        try await offCallerActor { try self.removeAllSynchronously() }
    }

    /// Runs `work` off whatever actor called, and waits for it.
    ///
    /// Detached rather than a plain `Task`, so it does not inherit the caller's
    /// actor — inheriting it is exactly the bug this avoids.
    private func offCallerActor<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    // MARK: - Synchronous implementation

    public func apiKeySynchronously(for server: VictualServer) throws -> VictualAPIKey? {
        guard let data = try readValue(service: configuration.service, for: server) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw VictualCredentialStoreError.malformedStoredValue
        }
        return VictualAPIKey(text)
    }

    public func saveSynchronously(_ apiKey: VictualAPIKey, for server: VictualServer) throws {
        try writeValue(Data(apiKey.rawValue.utf8), service: configuration.service, for: server)
    }

    public func removeAPIKeySynchronously(for server: VictualServer) throws {
        try deleteValue(service: configuration.service, for: server)
    }

    public func edgeCredentialSynchronously(for server: VictualServer) throws -> VictualEdgeCredential? {
        guard let data = try readValue(service: configuration.edgeTokenService, for: server) else { return nil }
        do {
            return try JSONDecoder().decode(VictualEdgeCredential.self, from: data)
        } catch {
            throw VictualCredentialStoreError.malformedStoredValue
        }
    }

    public func saveSynchronously(_ edgeCredential: VictualEdgeCredential, for server: VictualServer) throws {
        let value = try JSONEncoder().encode(edgeCredential)
        try writeValue(value, service: configuration.edgeTokenService, for: server)
    }

    public func removeEdgeCredentialSynchronously(for server: VictualServer) throws {
        try deleteValue(service: configuration.edgeTokenService, for: server)
    }

    // MARK: - Items

    private func readValue(service: String, for server: VictualServer) throws -> Data? {
        var query = baseQuery(service: service)
        query[kSecAttrAccount as String] = account(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw VictualCredentialStoreError.malformedStoredValue
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw VictualCredentialStoreError.keychain(status: status, operation: "read")
        }
    }

    private func writeValue(_ value: Data, service: String, for server: VictualServer) throws {
        var query = baseQuery(service: service)
        query[kSecAttrAccount as String] = account(for: server)

        var attributes = query
        attributes[kSecValueData as String] = value
        attributes[kSecAttrGeneric as String] = Data(server.apiPathPrefix.utf8)
        attributes[kSecAttrAccessible as String] = configuration.accessibility.rawValue

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // An item for this instance already exists; replace its contents
            // rather than leaving the stale key in place. The accessibility is
            // rewritten too, which is how an item saved under an older policy
            // moves to the current one on the next successful connection.
            let update: [String: Any] = [
                kSecValueData as String: value,
                kSecAttrGeneric as String: Data(server.apiPathPrefix.utf8),
                kSecAttrAccessible as String: configuration.accessibility.rawValue,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw VictualCredentialStoreError.keychain(status: updateStatus, operation: "update")
            }
        default:
            throw VictualCredentialStoreError.keychain(status: addStatus, operation: "save")
        }
    }

    private func deleteValue(service: String, for server: VictualServer) throws {
        var query = baseQuery(service: service)
        query[kSecAttrAccount as String] = account(for: server)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VictualCredentialStoreError.keychain(status: status, operation: "delete")
        }
    }

    // MARK: - Enumeration and clearing

    public func savedServersSynchronously() throws -> [VictualServer] {
        try storedAttributes()
            .compactMap(server(fromAttributes:))
            .sorted { $0.baseURL.absoluteString < $1.baseURL.absoluteString }
    }

    /// Forgets every key and token this store has written.
    ///
    /// Scoped to ``Configuration/service``, ``Configuration/edgeTokenService``
    /// and the access group, so it cannot reach another app's items.
    public func removeAllSynchronously() throws {
        // Deleting account by account rather than with one broad query: against
        // the file-based Keychain on macOS, a `SecItemDelete` that matches
        // several items removes only one of them and still reports success.
        for service in [configuration.service, configuration.edgeTokenService] {
            for account in try savedAccounts(service: service) {
                var query = baseQuery(service: service)
                query[kSecAttrAccount as String] = account
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw VictualCredentialStoreError.keychain(status: status, operation: "delete all")
                }
            }
        }
    }

    private func storedAttributes(service: String? = nil) throws -> [[String: Any]] {
        var query = baseQuery(service: service ?? configuration.service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            // A single match comes back as one dictionary rather than an array.
            if let items = result as? [[String: Any]] { return items }
            if let item = result as? [String: Any] { return [item] }
            return []
        case errSecItemNotFound:
            return []
        default:
            throw VictualCredentialStoreError.keychain(status: status, operation: "enumerate")
        }
    }

    private func savedAccounts(service: String) throws -> [String] {
        try storedAttributes(service: service).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - Query construction

    private func baseQuery(service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if configuration.synchronizesWithiCloud {
            query[kSecAttrSynchronizable as String] = true
        }
        #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] =
                configuration.usesDataProtectionKeychain
        #endif
        return query
    }

    private func account(for server: VictualServer) -> String {
        server.instanceURL.absoluteString
    }

    private func server(fromAttributes attributes: [String: Any]) -> VictualServer? {
        guard
            let account = attributes[kSecAttrAccount as String] as? String,
            let instanceURL = URL(string: account)
        else { return nil }

        let prefix =
            (attributes[kSecAttrGeneric as String] as? Data)
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "api"

        return VictualServer(instanceURL: instanceURL, apiPathPrefix: prefix)
    }
}
