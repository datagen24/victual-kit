import Foundation
import VictualCore

/// What a drain did.
struct DrainReport: Equatable {
    var sent = 0
    /// Records the server refused for a reason a retry cannot fix.
    var held = 0
}

/// Reads Health changes into a durable outbox and sends the outbox.
///
/// Two steps, so that offline is just "the second step did nothing":
/// ``pull()`` writes the outbox and *then* advances the anchor; ``drain()`` sends
/// in order and stops at the first failure a retry could fix.
actor DoseSyncEngine {
    private let source: any DoseEventSource
    private let submitter: any ConsumptionEventSubmitter
    private let storage: any SyncStateStore
    private let accountKey: AccountKey
    private let anchorKey: AnchorKey
    private let mappings: MappingSet
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone

    init(
        source: any DoseEventSource,
        submitter: any ConsumptionEventSubmitter,
        storage: any SyncStateStore,
        server: String,
        account: String,
        mappings: MappingSet,
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.source = source
        self.submitter = submitter
        self.storage = storage
        self.accountKey = AccountKey(server: server, account: account)
        self.anchorKey = AnchorKey(accountKey: accountKey, mappingSet: mappings.id)
        self.mappings = mappings
        self.now = now
        self.zone = zone
    }

    func queue() async throws -> SyncQueue {
        try await storage.loadQueue(for: accountKey)
    }

    @discardableResult
    func pull() async throws -> PlanReport {
        var queue = try await storage.loadQueue(for: accountKey)
        let anchor = try await storage.loadAnchor(for: anchorKey)
        let batch = try await source.changes(since: anchor, mappings: mappings)

        // Ask Health who is still authorized only if a deletion needs the evidence.
        let needsEvidence = batch.deleted.contains { queue.ledger[$0]?.state == .taken }
        let availability = needsEvidence ? try await source.availability() : nil

        let report = DoseSyncPlanner.apply(
            batch, to: &queue, mappings: mappings, availability: availability,
            now: now(), zone: zone())
        // Outbox first. A crash here replays the batch, and the ledger makes that a no-op.
        try await storage.saveQueue(queue, for: accountKey)
        try await storage.saveAnchor(batch.anchor, for: anchorKey)
        return report
    }

    /// Sends the outbox in order.
    ///
    /// - Throws: The `VictualError` that stopped it — `unauthorized`, `forbidden`
    ///   or a retryable failure. Progress made before it is already saved.
    @discardableResult
    func drain() async throws -> DrainReport {
        var queue = try await storage.loadQueue(for: accountKey)
        var report = DrainReport()

        for record in queue.outbox.sorted(by: { $0.sequence < $1.sequence }) where !record.held {
            do {
                switch record.operation {
                case .put(let submission):
                    let result = try await submitter.put(submission, sourceEventID: record.eventID)
                    queue.results[record.eventID] = result
                case .delete(let reason):
                    do {
                        let result = try await submitter.delete(sourceEventID: record.eventID, reason: reason)
                        queue.results[record.eventID] = result
                    } catch VictualError.notFound {
                        // The server never had it: nothing to delete.
                    }
                }
                queue.outbox.removeAll { $0.sequence == record.sequence }
                report.sent += 1
                try await storage.saveQueue(queue, for: accountKey)
            } catch {
                let failure = VictualError.mapping(error)
                guard let index = queue.outbox.firstIndex(where: { $0.sequence == record.sequence }) else { throw failure }
                queue.outbox[index].attempts += 1
                queue.outbox[index].lastError = failure.localizedDescription
                switch failure {
                case .unauthorized, .forbidden:
                    try await storage.saveQueue(queue, for: accountKey)
                    throw failure
                default:
                    if failure.isRetryable {
                        try await storage.saveQueue(queue, for: accountKey)
                        throw failure
                    }
                    queue.outbox[index].held = true
                    report.held += 1
                    try await storage.saveQueue(queue, for: accountKey)
                }
            }
        }
        return report
    }

    func resolve(sourceEventID: String, action: ResolutionAction) async throws {
        let result = try await submitter.resolve(sourceEventID: sourceEventID, action: action)
        var queue = try await storage.loadQueue(for: accountKey)
        queue.results[sourceEventID] = result
        try await storage.saveQueue(queue, for: accountKey)
    }

    /// One action for many events, in one request per 50. Events the server
    /// refused keep their last known state; the first refusal is returned.
    func resolveBulk(sourceEventIDs: [String], action: ResolutionAction) async throws -> BulkResolveOutcome? {
        let outcomes = try await submitter.resolve(sourceEventIDs: sourceEventIDs, action: action)
        var queue = try await storage.loadQueue(for: accountKey)
        for outcome in outcomes {
            if let event = outcome.event { queue.results[outcome.sourceEventID] = event }
        }
        try await storage.saveQueue(queue, for: accountKey)
        return outcomes.first { $0.event == nil }
    }
}
