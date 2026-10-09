import Foundation
import Observation
import VictualCore

/// Where a sync is in its cycle.
///
/// Shaped like `LoadState` in `VictualStock`, which this target does not depend on.
/// ``failed`` is deliberately loud: sync that fails *silently* when the API key
/// lapses is the failure the plan worries about.
public enum SyncState: Sendable {
    case idle
    case syncing
    /// The last sync finished.
    case synced
    /// The last sync stopped. Unsent records stay queued.
    case failed(VictualError)

    public var error: VictualError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

/// Whether the server can take medication events at all.
public enum ConsumptionAvailability: Sendable, Equatable {
    /// Not asked yet.
    case unknown
    case available
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        /// `GET /consumption/capabilities` answered `404`.
        case olderServer
        /// The server answered but lacks features this client needs.
        case missingFeatures([String])
    }
}

/// A row the Medications screen shows because a person has something to do or know.
public enum ReviewRow: Sendable, Equatable, Identifiable {
    /// Doses for a medication nobody has mapped yet. Nothing was sent.
    case needsMapping(medicationRef: String)
    /// Deletions Health made without saying why. One row per medication, however many.
    case sourceDeleted(medicationRef: String, eventIDs: [String])
    /// Health's unit string, exactly as sent, for the person to approve.
    case unitUnconfirmed(eventID: String, label: String)
    /// Any other `needs_review`, with the server's reason unrewritten.
    case needsReview(eventID: String, reason: ConsumptionReviewReason?)
    /// A manual booking that might be the same dose.
    case possibleDuplicate(eventID: String, transactionIDs: [String])

    public var id: String {
        switch self {
        case .needsMapping(let ref): "mapping:\(ref)"
        case .sourceDeleted(let ref, _): "deleted:\(ref)"
        case .unitUnconfirmed(let id, _): "unit:\(id)"
        case .needsReview(let id, _): "review:\(id)"
        case .possibleDuplicate(let id, _): "duplicate:\(id)"
        }
    }

    static func rows(from queue: SyncQueue, needsMapping: Set<String>) -> [ReviewRow] {
        var rows = needsMapping.sorted().map { ReviewRow.needsMapping(medicationRef: $0) }
        var deletedByMedication: [String: [String]] = [:]
        var mappingByMedication = Set<String>()

        for (id, event) in queue.results.sorted(by: { $0.key < $1.key }) {
            let ref = queue.ledger[id]?.medicationRef ?? ""
            switch (event.state, event.reason) {
            case (.needsMapping, _):
                mappingByMedication.insert(ref)
            case (.needsReview, .sourceDeleted):
                deletedByMedication[ref, default: []].append(id)
            case (.needsReview, .unitUnconfirmed):
                rows.append(.unitUnconfirmed(eventID: id, label: event.unitLabelSeen ?? ""))
            case (.needsReview, let reason):
                rows.append(.needsReview(eventID: id, reason: reason))
            default:
                break
            }
            if let duplicates = event.possibleDuplicates, !duplicates.isEmpty {
                rows.append(.possibleDuplicate(eventID: id, transactionIDs: duplicates.compactMap(\.transactionID)))
            }
        }
        for ref in mappingByMedication.subtracting(needsMapping).sorted() {
            rows.append(.needsMapping(medicationRef: ref))
        }
        for (ref, ids) in deletedByMedication.sorted(by: { $0.key < $1.key }) {
            rows.append(.sourceDeleted(medicationRef: ref, eventIDs: ids))
        }
        return rows
    }
}

/// What the phone's Medications screen reads.
///
/// ``sync()`` pulls Health changes into the outbox and sends it. It never throws:
/// a failure lands in ``state`` and unsent records stay queued, so offline is
/// just a later retry. Doses are never sent on launch by this type; the caller
/// decides when to sync, per the plan's foreground-driven delivery.
@MainActor
@Observable
public final class MedicationSyncStore {
    public private(set) var state: SyncState = .idle
    public private(set) var availability: ConsumptionAvailability = .unknown
    public private(set) var lastSynced: Date?
    public private(set) var reviewRows: [ReviewRow] = []
    /// Records the server refused and a retry cannot fix.
    public private(set) var heldCount = 0
    /// Mapped medications whose authorization disappeared. They need re-granting.
    public private(set) var unavailableMedications: Set<String> = []
    /// Medications with doses in Health but no mapping.
    public private(set) var needsMapping: Set<String> = []

    private let source: any DoseEventSource
    private let submitter: any ConsumptionEventSubmitter
    private let storage: any SyncStateStore
    private let server: String
    private let account: String
    private let requiredFeatures: Set<String>
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private var engine: DoseSyncEngine
    private var mappings: MappingSet

    /// - Parameters:
    ///   - server: The instance's base URL as text. Keys the anchor.
    ///   - account: Who is signed in on that server. Keys the anchor.
    ///   - requiredFeatures: Feature names `GET /consumption/capabilities` must list.
    ///     The fragment names none yet; Phase 3 fills this in from the merged contract.
    init(
        source: any DoseEventSource,
        submitter: any ConsumptionEventSubmitter,
        storage: any SyncStateStore,
        server: String,
        account: String,
        mappings: MappingSet = MappingSet(),
        requiredFeatures: Set<String> = [],
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.source = source
        self.submitter = submitter
        self.storage = storage
        self.server = server
        self.account = account
        self.mappings = mappings
        self.requiredFeatures = requiredFeatures
        self.now = now
        self.zone = zone
        self.engine = DoseSyncEngine(
            source: source, submitter: submitter, storage: storage, server: server,
            account: account, mappings: mappings, now: now, zone: zone)
    }

    /// Persists in `directory`, which belongs to this app.
    public convenience init(
        source: any DoseEventSource,
        submitter: any ConsumptionEventSubmitter,
        directory: URL,
        server: String,
        account: String,
        mappings: MappingSet = MappingSet(),
        requiredFeatures: Set<String> = []
    ) {
        self.init(
            source: source, submitter: submitter, storage: FileSyncStateStore(directory: directory),
            server: server, account: account, mappings: mappings, requiredFeatures: requiredFeatures)
    }

    /// Asks the server whether it takes medication events.
    ///
    /// A `404` is an older server and is not a failure: the screen says so.
    public func checkAvailability() async {
        do {
            let capabilities = try await submitter.capabilities()
            let missing = requiredFeatures.subtracting(capabilities.features).sorted()
            availability = missing.isEmpty ? .available : .unavailable(.missingFeatures(missing))
        } catch {
            switch VictualError.mapping(error) {
            case .notFound: availability = .unavailable(.olderServer)
            case let failure: state = .failed(failure)
            }
        }
    }

    /// Replaces the mappings. A different mapping set restarts the read at each
    /// `effectiveFrom`; the outbox and ledger carry over.
    public func setMappings(_ mappings: MappingSet) {
        guard mappings != self.mappings else { return }
        self.mappings = mappings
        engine = DoseSyncEngine(
            source: source, submitter: submitter, storage: storage, server: server,
            account: account, mappings: mappings, now: now, zone: zone)
    }

    /// Pulls, then sends.
    public func sync() async {
        if availability == .unknown { await checkAvailability() }
        guard availability == .available else { return }
        state = .syncing
        do {
            let report = try await engine.pull()
            needsMapping = report.needsMapping
            unavailableMedications.formUnion(report.revoked)
            try await engine.drain()
            lastSynced = now()
            state = .synced
        } catch {
            state = .failed(VictualError.mapping(error))
        }
        await refresh()
    }

    /// Approves the unit string Health sent, so this and later doses book.
    public func approveUnit(eventID: String) async {
        do {
            try await engine.resolve(sourceEventID: eventID, action: .approveUnit)
        } catch {
            state = .failed(VictualError.mapping(error))
        }
        await refresh()
    }

    /// Applies `void` or `keep` to every deletion queued for one medication,
    /// so a cleared history is one decision and not one per dose.
    public func resolveDeletions(medicationRef: String, action: ResolutionAction) async {
        guard action == .void || action == .keep else { return }
        for case .sourceDeleted(let ref, let ids) in reviewRows where ref == medicationRef {
            for id in ids {
                do {
                    try await engine.resolve(sourceEventID: id, action: action)
                } catch {
                    state = .failed(VictualError.mapping(error))
                    break
                }
            }
        }
        await refresh()
    }

    private func refresh() async {
        guard let queue = try? await engine.queue() else { return }
        reviewRows = ReviewRow.rows(from: queue, needsMapping: needsMapping)
        heldCount = queue.outbox.filter(\.held).count
    }

    /// The latest server state for a dose, if one has been sent.
    public func serverState(for eventID: String) async -> ConsumptionEventState? {
        try? await engine.queue().results[eventID]?.state
    }
}
