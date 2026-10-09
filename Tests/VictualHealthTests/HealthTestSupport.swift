import Foundation
import VictualCore
@testable import VictualHealth

/// A source that returns what the test scripted, in order, and records what it was asked.
final class ScriptedSource: DoseEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [DoseEventBatch]
    private var _availability: [String: MedicationAvailability]
    private var _anchorsSeen: [Data?] = []
    private var _availabilityQueries = 0

    init(_ batches: [DoseEventBatch], availability: [String: MedicationAvailability] = [:]) {
        self.batches = batches
        self._availability = availability
    }

    var anchorsSeen: [Data?] { lock.withLock { _anchorsSeen } }
    var availabilityQueries: Int { lock.withLock { _availabilityQueries } }

    func enqueue(_ batch: DoseEventBatch) { lock.withLock { batches.append(batch) } }

    func changes(since anchor: Data?, mappings: MappingSet) async throws -> DoseEventBatch {
        lock.withLock {
            _anchorsSeen.append(anchor)
            return batches.isEmpty ? DoseEventBatch(anchor: anchor ?? Data()) : batches.removeFirst()
        }
    }

    func availability() async throws -> [String: MedicationAvailability] {
        lock.withLock {
            _availabilityQueries += 1
            return _availability
        }
    }
}

/// A submitter that records every call and can be told to fail.
final class FakeSubmitter: ConsumptionEventSubmitter, @unchecked Sendable {
    enum Call: Equatable {
        case put(id: String, body: Data)
        case delete(id: String, reason: DeletionReason?)
        case resolve(id: String, action: ResolutionAction)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var failures: [(Call) -> VictualError?] = []
    private var responses: [String: ConsumptionEvent] = [:]
    private var _capabilities: Result<ConsumptionCapabilities, VictualError> =
        .success(.init(contractVersion: 1, features: []))

    var calls: [Call] { lock.withLock { _calls } }
    var puts: [ConsumptionEventSubmission] {
        calls.compactMap {
            if case .put(_, let body) = $0 { try? JSONDecoder().decode(ConsumptionEventSubmission.self, from: body) } else { nil }
        }
    }
    var deletes: [(id: String, reason: DeletionReason?)] {
        calls.compactMap { if case .delete(let id, let reason) = $0 { (id, reason) } else { nil } }
    }

    func failWhen(_ predicate: @escaping (Call) -> VictualError?) { lock.withLock { failures.append(predicate) } }
    func clearFailures() { lock.withLock { failures = [] } }
    func respond(to id: String, with event: ConsumptionEvent) { lock.withLock { responses[id] = event } }
    func setCapabilities(_ result: Result<ConsumptionCapabilities, VictualError>) { lock.withLock { _capabilities = result } }

    private func record(_ call: Call, id: String, default state: ConsumptionEventState) throws -> ConsumptionEvent {
        try lock.withLock {
            _calls.append(call)
            for predicate in failures { if let error = predicate(call) { throw error } }
            return responses[id] ?? ConsumptionEvent(sourceEventID: id, state: state)
        }
    }

    func put(_ submission: ConsumptionEventSubmission, sourceEventID: String) async throws -> ConsumptionEvent {
        try record(.put(id: sourceEventID, body: try submission.encoded()), id: sourceEventID, default: .booked)
    }

    func delete(sourceEventID: String, reason: DeletionReason?) async throws -> ConsumptionEvent {
        try record(.delete(id: sourceEventID, reason: reason), id: sourceEventID, default: .voided)
    }

    func resolve(sourceEventID: String, action: ResolutionAction) async throws -> ConsumptionEvent {
        try record(.resolve(id: sourceEventID, action: action), id: sourceEventID, default: .booked)
    }

    func capabilities() async throws -> ConsumptionCapabilities {
        try lock.withLock { try _capabilities.get() }
    }
}

/// In-memory state with crash injection between the queue and anchor writes.
actor MemoryStateStore: SyncStateStore {
    private var queues: [AccountKey: SyncQueue] = [:]
    private var anchors: [AnchorKey: Data] = [:]
    private(set) var writeLog: [String] = []
    var failNextAnchorWrite = false

    struct Crash: Error {}

    func setFailNextAnchorWrite(_ value: Bool) { failNextAnchorWrite = value }

    func loadQueue(for key: AccountKey) -> SyncQueue { queues[key] ?? SyncQueue() }

    func saveQueue(_ queue: SyncQueue, for key: AccountKey) {
        writeLog.append("queue")
        queues[key] = queue
    }

    func loadAnchor(for key: AnchorKey) -> Data? { anchors[key] }

    func saveAnchor(_ anchor: Data, for key: AnchorKey) throws {
        if failNextAnchorWrite {
            failNextAnchorWrite = false
            throw Crash()
        }
        writeLog.append("anchor")
        anchors[key] = anchor
    }
}

enum Fixtures {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21T14:13:20Z
    static let zone = TimeZone(identifier: "America/New_York")!

    static func mapping(
        _ ref: String = "hk:med:42", effectiveFrom: Date = t0 - 86_400,
        location: MappingLocation = .init(mode: .fixed, locationID: 9)
    ) -> Mapping {
        Mapping(medicationRef: ref, target: .product(17), location: location, effectiveFrom: effectiveFrom)
    }

    static func dose(
        _ id: String, ref: String = "hk:med:42", status: DoseLogStatus = .taken,
        quantity: Double? = 1, unit: String = "tablet", at: Date = t0 + 3600,
        scheduled: Date? = nil, type: DoseScheduleType = .asNeeded
    ) -> DoseEvent {
        DoseEvent(id: id, medicationRef: ref, status: status, quantity: quantity, unit: unit,
                  occurredAt: at, scheduledDate: scheduled, scheduleType: type)
    }

    static func batch(
        _ inserted: [DoseEvent] = [], deleted: [String] = [], anchor: String = "a1"
    ) -> DoseEventBatch {
        DoseEventBatch(inserted: inserted, deleted: deleted, anchor: Data(anchor.utf8))
    }

    static func engine(
        source: ScriptedSource, submitter: FakeSubmitter = FakeSubmitter(),
        storage: MemoryStateStore = MemoryStateStore(), account: String = "me",
        server: String = "https://v.example", mappings: [Mapping] = [mapping()],
        now: @escaping @Sendable () -> Date = { t0 }
    ) -> DoseSyncEngine {
        DoseSyncEngine(
            source: source, submitter: submitter, storage: storage, server: server,
            account: account, mappings: MappingSet(mappings), now: now, zone: { zone })
    }
}
