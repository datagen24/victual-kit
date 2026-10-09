import Foundation

/// The six states Health gives a dose event's `logStatus`.
///
/// A copy of `HKMedicationDoseEvent.LogStatus` so the sync logic can be written
/// and tested without importing HealthKit.
public enum DoseLogStatus: String, CaseIterable, Sendable, Codable {
    case taken
    case skipped
    case snoozed
    case notInteracted
    case notificationNotSent
    case notLogged
}

/// Whether a dose was on a schedule or taken as needed.
///
/// Used only by the `replaces` heuristic: an as-needed dose has no natural key.
public enum DoseScheduleType: String, CaseIterable, Sendable, Codable {
    case schedule
    case asNeeded
}

/// One dose event, as the sync logic sees it.
///
/// A plain value: the HealthKit adapter builds it from an `HKMedicationDoseEvent`,
/// and a test builds it directly. Nothing in it is a medication name — the
/// payload sent to the server carries an opaque reference, never a drug.
public struct DoseEvent: Sendable, Equatable, Codable, Identifiable {
    /// `HKObject.uuid.uuidString`. Not stable across an edit, which Health
    /// performs as delete-and-recreate.
    public var id: String
    /// The opaque `medication_ref`, already derived from the medication concept
    /// identifier by the adapter.
    public var medicationRef: String
    public var status: DoseLogStatus
    /// `doseQuantity`, which Health may not have. `nil` is never replaced with a number.
    public var quantity: Double?
    /// `unit.unitString`, matched server-side against the mapping's confirmed labels.
    public var unit: String
    /// `startDate`. When the dose happened, not when it was logged or scheduled.
    public var occurredAt: Date
    public var scheduledDate: Date?
    public var scheduleType: DoseScheduleType

    public init(
        id: String,
        medicationRef: String,
        status: DoseLogStatus,
        quantity: Double? = nil,
        unit: String,
        occurredAt: Date,
        scheduledDate: Date? = nil,
        scheduleType: DoseScheduleType = .asNeeded
    ) {
        self.id = id
        self.medicationRef = medicationRef
        self.status = status
        self.quantity = quantity
        self.unit = unit
        self.occurredAt = occurredAt
        self.scheduledDate = scheduledDate
        self.scheduleType = scheduleType
    }
}

/// What a source reports about one medication when asked now.
///
/// A medication absent from the answer is no longer authorized.
public enum MedicationAvailability: String, Sendable, Codable {
    case active
    case archived
}

/// What a source returns for one anchored query.
public struct DoseEventBatch: Sendable, Equatable {
    /// New or changed samples.
    public var inserted: [DoseEvent]
    /// `HKDeletedObject` uuids, which carry nothing else.
    public var deleted: [String]
    /// The opaque anchor to pass back next time.
    public var anchor: Data

    public init(inserted: [DoseEvent] = [], deleted: [String] = [], anchor: Data) {
        self.inserted = inserted
        self.deleted = deleted
        self.anchor = anchor
    }
}

/// Where dose events come from.
///
/// `HealthKitDoseSource` conforms in a later phase; tests conform with a script.
public protocol DoseEventSource: Sendable {
    /// Samples and deletions since `anchor`, for the mapped medications only and
    /// no earlier than each mapping's `effectiveFrom`, so that connecting never
    /// reads old history. A `nil` anchor reads from `effectiveFrom`.
    func changes(since anchor: Data?, mappings: MappingSet) async throws -> DoseEventBatch

    /// The medications currently authorized, queried fresh. The evidence the
    /// deletion-reason rule needs.
    func availability() async throws -> [String: MedicationAvailability]
}
