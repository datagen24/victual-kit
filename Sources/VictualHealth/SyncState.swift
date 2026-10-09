import CryptoKit
import Foundation

/// Whose queue: one per server and account.
///
/// The outbox and ledger belong to the person, not to a mapping set. If they
/// were keyed by mapping set, re-mapping would orphan unsent records.
struct AccountKey: Sendable, Hashable, Codable {
    var server: String
    var account: String
}

/// Whose anchor: server, account *and* mapping set.
///
/// An anchor says "everything up to here has been read under these mappings".
/// Another server, another person, or another mapping set must not inherit it.
struct AnchorKey: Sendable, Hashable, Codable {
    var accountKey: AccountKey
    var mappingSet: String

    /// A file-name-safe digest. A server URL or account name is not a safe path component.
    var fileStem: String {
        let text = [accountKey.server, accountKey.account, mappingSet].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One thing waiting to be sent.
struct OutboxRecord: Sendable, Equatable, Codable {
    enum Operation: Sendable, Equatable, Codable {
        case put(ConsumptionEventSubmission)
        case delete(reason: DeletionReason?)
    }

    var sequence: Int
    var eventID: String
    var operation: Operation
    var attempts = 0
    /// The last failure, kept so a held record can say why.
    var lastError: String?
    /// A record the server refused for a reason retrying cannot fix. It stays
    /// visible rather than blocking the ones behind it.
    var held = false
}

/// What the client knows it has sent for one `source_event_id`.
///
/// More than an id: a deletion arrives as a bare uuid, and everything the
/// `replaces` rule and the deletion-reason table need must come from here.
struct LedgerEntry: Sendable, Equatable, Codable, Identifiable {
    enum State: String, Sendable, Codable {
        /// Sent (or queued) as `taken`.
        case taken
        /// Sent a later non-taken status for it.
        case retracted
        /// Deleted, with whatever reason was justified.
        case removed
        /// Superseded by an event carrying `replaces`.
        case replaced
    }

    var id: String
    var medicationRef: String
    var occurredAt: Date
    var quantity: Double?
    var unit: String
    var scheduledDate: Date?
    var scheduleType: DoseScheduleType
    var state: State
}

/// The durable part of a sync: what to send, what was sent, what the server said.
struct SyncQueue: Sendable, Equatable, Codable {
    var outbox: [OutboxRecord] = []
    var ledger: [String: LedgerEntry] = [:]
    /// The latest server answer per event, for the review list.
    var results: [String: ConsumptionEvent] = [:]
    var nextSequence = 1
}

/// Persistence for a sync, as two writes so that their order is a rule of the
/// engine and not an accident of one file.
///
/// The queue is written before the anchor advances: a crash between the two
/// replays the batch, and the ledger makes the replay a no-op, whereas the
/// other order would lose events.
protocol SyncStateStore: Sendable {
    func loadQueue(for key: AccountKey) async throws -> SyncQueue
    func saveQueue(_ queue: SyncQueue, for key: AccountKey) async throws
    func loadAnchor(for key: AnchorKey) async throws -> Data?
    func saveAnchor(_ anchor: Data, for key: AnchorKey) async throws
}

/// Keeps the queue and anchors as files in one directory.
///
/// Files are written atomically and, where the platform has file protection,
/// `completeUntilFirstUserAuthentication`: a background sync can read them after
/// the first unlock, and they are encrypted at rest before it. macOS has no such
/// option; nothing here runs on a Mac in production.
public actor FileSyncStateStore: SyncStateStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The options every write uses.
    static var writeOptions: Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return options
    }

    /// Whether ``writeOptions`` asks for file protection on this platform.
    static var requestsFileProtection: Bool {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            true
        #else
            false
        #endif
    }

    func loadQueue(for key: AccountKey) throws -> SyncQueue {
        guard let data = try read(queueFile(key)) else { return SyncQueue() }
        return try JSONDecoder().decode(SyncQueue.self, from: data)
    }

    func saveQueue(_ queue: SyncQueue, for key: AccountKey) throws {
        try write(JSONEncoder().encode(queue), to: queueFile(key))
    }

    func loadAnchor(for key: AnchorKey) throws -> Data? {
        try read(directory.appendingPathComponent("anchor-\(key.fileStem).bin"))
    }

    func saveAnchor(_ anchor: Data, for key: AnchorKey) throws {
        try write(anchor, to: directory.appendingPathComponent("anchor-\(key.fileStem).bin"))
    }

    private func queueFile(_ key: AccountKey) -> URL {
        let stem = AnchorKey(accountKey: key, mappingSet: "").fileStem
        return directory.appendingPathComponent("queue-\(stem).json")
    }

    private func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: Self.writeOptions)
    }
}
