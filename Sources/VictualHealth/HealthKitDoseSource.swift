#if canImport(HealthKit) && compiler(>=6.2)
// `compiler(>=6.2)` stands in for the iOS 26 SDK: HealthKit exists in older SDKs, but the
// medication types do not, and CI's Xcode 16.4 (Swift 6.1) must still build this target.
import Foundation
import HealthKit

// The only file in the package that turns HealthKit objects into the plain
// values the sync logic uses. Everything here is iOS 26: medication types do not
// exist earlier, and the package's own floor does not move. The attribute lists
// the other platforms that HealthKit's medication API names, because the package
// also builds for macOS 14+ and an `iOS 26`-only attribute would not satisfy the
// compiler there.

/// A medication the person has authorized, for the screens that name it.
///
/// ``displayName`` exists so the mapping and review screens can show the person
/// their own medication. It is held in memory only: never log it, persist it, or
/// send it to the server.
@available(iOS 26, macOS 26, macCatalyst 26, watchOS 26, visionOS 26, *)
public struct HealthMedication: Sendable, Equatable, Identifiable {
    /// The opaque `medication_ref`.
    public var ref: String
    public var id: String { ref }
    public var displayName: String
    public var isArchived: Bool
    public var hasSchedule: Bool
}

/// Reads medication dose events from Health.
///
/// Read-only: nothing here writes to Health or asks to. Authorization is a
/// separate explicit step, ``requestMedicationAuthorization()``, because Health
/// shows its sheet every time it is asked and it must only follow a person's tap.
@available(iOS 26, macOS 26, macCatalyst 26, watchOS 26, visionOS 26, *)
public struct HealthKitDoseSource: DoseEventSource {
    private let store: HKHealthStore
    private let now: @Sendable () -> Date

    /// How far back events are read when nothing is mapped yet.
    ///
    /// A medication with no mapping has no `effective_from`, and the client sends
    /// nothing for it. The read exists only so the screen can say "needs mapping",
    /// so it is short.
    static let unmappedLookback: TimeInterval = 30 * 24 * 60 * 60

    public init(store: HKHealthStore = HKHealthStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Whether this device has Health data at all (an iPad without Health does not).
    public static var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Shows Health's medication sheet, where the person ticks the medications to share.
    ///
    /// Read only: `requestAuthorization(toShare:read:)` fails for these types.
    /// Health prompts every time, so call this only from an explicit "Choose
    /// medications" action.
    public func requestMedicationAuthorization() async throws {
        try await store.requestPerObjectReadAuthorization(
            for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
    }

    /// The medications the person has authorized, archived ones included.
    public func medications() async throws -> [HealthMedication] {
        try await annotatedMedications().map { entry in
            HealthMedication(
                ref: entry.candidates.chosen, displayName: entry.displayName,
                isArchived: entry.medication.isArchived, hasSchedule: entry.medication.hasSchedule)
        }
    }

    // MARK: DoseEventSource

    public func changes(since anchor: Data?, mappings: MappingSet) async throws -> DoseEventBatch {
        let lowerBound = mappings.mappings.values.map(\.effectiveFrom).min()
            ?? now().addingTimeInterval(-Self.unmappedLookback)
        let result = try await Self.anchoredResult(
            store: store, anchor: anchor.flatMap(Self.decodeAnchor), since: lowerBound)

        var inserted: [DoseEvent] = []
        for sample in result.addedSamples {
            guard let event = sample as? HKMedicationDoseEvent else { continue }
            let candidates = try Self.candidates(for: event.medicationConceptIdentifier)
            if let dose = DoseEvent(event, medicationRef: candidates.chosen) { inserted.append(dose) }
        }
        return DoseEventBatch(
            inserted: inserted,
            deleted: result.deletedObjects.map { $0.uuid.uuidString },
            anchor: try Self.encode(anchor: result.newAnchor))
    }

    public func availability() async throws -> [String: MedicationAvailability] {
        var answer: [String: MedicationAvailability] = [:]
        for entry in try await annotatedMedications() {
            answer[entry.candidates.chosen] = entry.medication.isArchived ? .archived : .active
        }
        return answer
    }

    // MARK: Shared with the device spike

    struct AnnotatedEntry {
        var medication: HKUserAnnotatedMedication
        var candidates: MedicationRef.Candidates
        var displayName: String
    }

    func annotatedMedications() async throws -> [AnnotatedEntry] {
        let found = try await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)
        return try found.map { medication in
            AnnotatedEntry(
                medication: medication,
                candidates: try Self.candidates(for: medication.medication.identifier),
                displayName: medication.nickname ?? medication.medication.displayText)
        }
    }

    /// Anchored read of every dose event no earlier than `start`.
    static func anchoredResult(
        store: HKHealthStore, anchor: HKQueryAnchor?, since start: Date
    ) async throws -> HKAnchoredObjectQueryDescriptor<HKSample>.Result {
        try await anchoredDescriptor(anchor: anchor, since: start).result(for: store)
    }

    static func anchoredDescriptor(anchor: HKQueryAnchor?, since start: Date?) -> HKAnchoredObjectQueryDescriptor<HKSample> {
        let predicate = start.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate) }
        return HKAnchoredObjectQueryDescriptor(
            predicates: [.sample(type: HKObjectType.medicationDoseEventType(), predicate: predicate)],
            anchor: anchor)
    }

    // MARK: Identifier to reference

    /// The secure-coded bytes of an identifier, or `nil` if it cannot be archived.
    static func archive(_ identifier: HKHealthConceptIdentifier) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true)
    }

    static func candidates(for identifier: HKHealthConceptIdentifier) throws -> MedicationRef.Candidates {
        guard let bytes = archive(identifier) else { throw HealthKitDoseSourceError.identifierNotArchivable }
        return MedicationRef.candidates(description: identifier.description, archive: bytes)
    }

    // MARK: Anchors

    static func encode(anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    static func decodeAnchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}

@available(iOS 26, macOS 26, macCatalyst 26, watchOS 26, visionOS 26, *)
public enum HealthKitDoseSourceError: Error, Sendable {
    /// A medication identifier would not archive, so no reference can be derived.
    case identifierNotArchivable
}

@available(iOS 26, macOS 26, macCatalyst 26, watchOS 26, visionOS 26, *)
extension DoseEvent {
    /// The plain value for one Health dose event, or `nil` if its `logStatus` is a
    /// case this build does not know (never mapped to a guess).
    init?(_ event: HKMedicationDoseEvent, medicationRef: String) {
        guard let status = DoseLogStatus(event.logStatus) else { return nil }
        self.init(
            id: event.uuid.uuidString,
            medicationRef: medicationRef,
            status: status,
            quantity: event.doseQuantity,
            unit: event.unit.unitString,
            occurredAt: event.startDate,
            scheduledDate: event.scheduledDate,
            scheduleType: DoseScheduleType(event.scheduleType))
    }
}

@available(iOS 26, macOS 26, macCatalyst 26, watchOS 26, visionOS 26, *)
extension DoseLogStatus {
    init?(_ status: HKMedicationDoseEvent.LogStatus) {
        switch status {
        case .taken: self = .taken
        case .skipped: self = .skipped
        case .snoozed: self = .snoozed
        case .notInteracted: self = .notInteracted
        case .notificationNotSent: self = .notificationNotSent
        case .notLogged: self = .notLogged
        @unknown default: return nil
        }
    }
}

@available(iOS 26, macOS 26, macCatalyst 26, watchOS 26, visionOS 26, *)
extension DoseScheduleType {
    init(_ type: HKMedicationDoseEvent.ScheduleType) {
        switch type {
        case .schedule: self = .schedule
        case .asNeeded: self = .asNeeded
        // A case this build does not know is treated as having no natural key,
        // which keeps it out of the `replaces` heuristic.
        @unknown default: self = .asNeeded
        }
    }
}
#endif
