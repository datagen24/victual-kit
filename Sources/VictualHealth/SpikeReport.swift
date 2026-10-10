import CryptoKit
import Foundation

// The device spike's findings, as plain values, and the text export built from
// them. None of this imports HealthKit, so the export's privacy rules are tested
// on a Mac: the report is built from types that have no field for a medication
// name or nickname, so it cannot leak one by formatting.

/// What the spike learned about one medication. No name, no nickname.
public struct SpikeMedicationFinding: Sendable, Equatable {
    /// `M1`, `M2`… in the order this launch first saw them. Not stable across launches.
    public var label: String
    public var candidates: MedicationRef.Candidates
    /// Whether archiving the identifier twice gave identical bytes.
    public var archiveRepeatable: Bool
    /// Whether archive, unarchive and archive again gave identical bytes.
    public var archiveRoundTrips: Bool
    /// `nil` when there was no previous launch to compare with.
    public var descriptionSeenLastLaunch: Bool?
    public var hashSeenLastLaunch: Bool?
    public var isArchived: Bool
    public var hasSchedule: Bool
    public var generalForm: String
    public var hasNickname: Bool
    /// Whether `description` contains the medication's name or nickname.
    /// A description that does is withheld from the export.
    public var descriptionContainsName: Bool

    public init(
        label: String, candidates: MedicationRef.Candidates, archiveRepeatable: Bool, archiveRoundTrips: Bool,
        descriptionSeenLastLaunch: Bool?, hashSeenLastLaunch: Bool?, isArchived: Bool, hasSchedule: Bool,
        generalForm: String, hasNickname: Bool, descriptionContainsName: Bool
    ) {
        self.label = label
        self.candidates = candidates
        self.archiveRepeatable = archiveRepeatable
        self.archiveRoundTrips = archiveRoundTrips
        self.descriptionSeenLastLaunch = descriptionSeenLastLaunch
        self.hashSeenLastLaunch = hashSeenLastLaunch
        self.isArchived = isArchived
        self.hasSchedule = hasSchedule
        self.generalForm = generalForm
        self.hasNickname = hasNickname
        self.descriptionContainsName = descriptionContainsName
    }
}

/// One thing an anchored query delivered.
public struct SpikeEventFinding: Sendable, Equatable {
    public enum Kind: String, Sendable { case inserted, deleted }

    public var kind: Kind
    /// The first four characters of the sample's uuid: enough to see that a
    /// deletion and a later insertion are different samples, nothing more.
    public var shortID: String
    public var arrivedAt: Date
    /// The medication's label, or `nil` for a deletion whose sample was never seen.
    public var medicationLabel: String?
    public var status: String?
    public var scheduleType: String?
    public var doseQuantity: Double?
    public var scheduledDoseQuantity: Double?
    public var unitString: String?
    public var startDate: Date?
    public var endDate: Date?
    public var scheduledDate: Date?
    /// `true` for the first delivery of a run, which replays history.
    public var initialDelivery: Bool

    public init(
        kind: Kind, shortID: String, arrivedAt: Date, medicationLabel: String? = nil, status: String? = nil,
        scheduleType: String? = nil, doseQuantity: Double? = nil, scheduledDoseQuantity: Double? = nil,
        unitString: String? = nil, startDate: Date? = nil, endDate: Date? = nil, scheduledDate: Date? = nil,
        initialDelivery: Bool
    ) {
        self.kind = kind
        self.shortID = shortID
        self.arrivedAt = arrivedAt
        self.medicationLabel = medicationLabel
        self.status = status
        self.scheduleType = scheduleType
        self.doseQuantity = doseQuantity
        self.scheduledDoseQuantity = scheduledDoseQuantity
        self.unitString = unitString
        self.startDate = startDate
        self.endDate = endDate
        self.scheduledDate = scheduledDate
        self.initialDelivery = initialDelivery
    }

    /// Seconds from the sample's `startDate` to its arrival. Only a latency when
    /// the person logged the dose "now"; a retroactive log reads as lateness.
    public var secondsAfterStart: TimeInterval? {
        startDate.map { arrivedAt.timeIntervalSince($0) }
    }
}

/// What a re-query after revoking one medication in Health showed.
public struct SpikeRevocationFinding: Sendable, Equatable {
    public var at: Date
    public var medicationsBefore: Int
    public var medicationsAfter: Int
    /// Labels present before and absent after.
    public var vanished: [String]
    /// From the previous anchor: samples added and objects deleted since.
    public var deltaAdded: Int
    public var deltaDeleted: Int
    /// From no anchor: how many samples a fresh read returns now.
    public var freshRead: Int

    public init(
        at: Date, medicationsBefore: Int, medicationsAfter: Int, vanished: [String],
        deltaAdded: Int, deltaDeleted: Int, freshRead: Int
    ) {
        self.at = at
        self.medicationsBefore = medicationsBefore
        self.medicationsAfter = medicationsAfter
        self.vanished = vanished
        self.deltaAdded = deltaAdded
        self.deltaDeleted = deltaDeleted
        self.freshRead = freshRead
    }
}

/// Where the spike ran.
public struct SpikeEnvironment: Sendable, Equatable {
    /// `iPhone17,3`: a hardware identifier, not a name the person chose.
    public var deviceModel: String
    public var osVersion: String
    public var buildConfiguration: String

    public init(deviceModel: String, osVersion: String, buildConfiguration: String) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.buildConfiguration = buildConfiguration
    }

    public static func current() -> SpikeEnvironment {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return SpikeEnvironment(
            deviceModel: String(cString: machine),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            buildConfiguration: configuration)
    }
}

/// Everything the spike gathered in one run.
public struct SpikeSnapshot: Sendable, Equatable {
    public var environment: SpikeEnvironment
    public var authorizationRequests: Int
    public var medications: [SpikeMedicationFinding]
    public var events: [SpikeEventFinding]
    public var revocations: [SpikeRevocationFinding]
    /// `nil` until tried; otherwise "accepted" or the error's domain and code.
    public var backgroundDelivery: String?
    /// Doses whose `logStatus` was a case this build does not know, dropped.
    public var unknownStatusCount: Int
    public var generatedAt: Date

    public init(
        environment: SpikeEnvironment, authorizationRequests: Int, medications: [SpikeMedicationFinding],
        events: [SpikeEventFinding], revocations: [SpikeRevocationFinding], backgroundDelivery: String?,
        unknownStatusCount: Int, generatedAt: Date
    ) {
        self.environment = environment
        self.authorizationRequests = authorizationRequests
        self.medications = medications
        self.events = events
        self.revocations = revocations
        self.backgroundDelivery = backgroundDelivery
        self.unknownStatusCount = unknownStatusCount
        self.generatedAt = generatedAt
    }
}

/// The plain-text export, made to be pasted into the plan's Executed section.
///
/// Rules, each tested: no medication name or nickname (the types hold none),
/// every timestamp rounded down to the minute, event identity reduced to four
/// characters, and a `description` that contains a name withheld.
public enum SpikeReport {
    public static func render(_ snapshot: SpikeSnapshot, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        func add(_ line: String = "") { lines.append(line) }

        add("Victual HealthKit spike report (no medication names or nicknames)")
        add("Generated \(minute(snapshot.generatedAt, timeZone))")
        add("Device \(snapshot.environment.deviceModel), \(snapshot.environment.osVersion), \(snapshot.environment.buildConfiguration) build")
        add("Per-medication authorization prompts shown this run: \(snapshot.authorizationRequests)")
        add("Background delivery for dose events: \(snapshot.backgroundDelivery ?? "not tried")")
        add("Dose events with an unknown logStatus (dropped): \(snapshot.unknownStatusCount)")
        add()

        add("== Medications (\(snapshot.medications.count)) ==")
        for med in snapshot.medications {
            add("\(med.label): form \(med.generalForm), archived \(yn(med.isArchived)), scheduled \(yn(med.hasSchedule)), has nickname \(yn(med.hasNickname))")
            add("  description candidate: \(describe(med))")
            add("  hash candidate: \(med.candidates.hashed)")
            add("  chosen ref: \(chosen(med))")
            add("  archive repeatable in process: \(yn(med.archiveRepeatable)); survives unarchive and archive: \(yn(med.archiveRoundTrips))")
            add("  seen at previous launch: description \(seen(med.descriptionSeenLastLaunch)), hash \(seen(med.hashSeenLastLaunch))")
        }
        add()

        add("== Events (\(snapshot.events.count)), in arrival order ==")
        add("Seconds after start is a delivery latency only if the dose was logged at that moment; initial deliveries replay history.")
        for event in snapshot.events {
            add(eventLine(event, timeZone))
        }
        add()

        add("== After revoking a medication (\(snapshot.revocations.count) re-queries) ==")
        for r in snapshot.revocations {
            let vanished = r.vanished.isEmpty ? "none" : r.vanished.joined(separator: ",")
            add("\(minute(r.at, timeZone)): medications \(r.medicationsBefore) -> \(r.medicationsAfter), vanished \(vanished); anchored delta +\(r.deltaAdded) -\(r.deltaDeleted); fresh read \(r.freshRead) samples")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func yn(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func seen(_ value: Bool?) -> String {
        value.map(yn) ?? "n/a (first launch)"
    }

    private static func describe(_ med: SpikeMedicationFinding) -> String {
        guard let description = med.candidates.description else { return "none" }
        if med.descriptionContainsName { return "withheld (contains the name); valid \(yn(med.candidates.descriptionIsValid))" }
        return "\"\(description)\" valid \(yn(med.candidates.descriptionIsValid))"
    }

    private static func chosen(_ med: SpikeMedicationFinding) -> String {
        med.candidates.chosen == med.candidates.description && med.descriptionContainsName
            ? "withheld (the description)" : med.candidates.chosen
    }

    private static func eventLine(_ event: SpikeEventFinding, _ zone: TimeZone) -> String {
        var parts = ["\(minute(event.arrivedAt, zone)) \(event.kind.rawValue) id#\(event.shortID)"]
        parts.append(event.initialDelivery ? "initial" : "update")
        if let label = event.medicationLabel { parts.append(label) }
        if let status = event.status { parts.append("status \(status)") }
        if let type = event.scheduleType { parts.append(type) }
        if event.kind == .inserted {
            parts.append("doseQuantity \(number(event.doseQuantity))")
            parts.append("scheduledDoseQuantity \(number(event.scheduledDoseQuantity))")
            parts.append("unit \"\(event.unitString ?? "nil")\"")
            parts.append("start \(event.startDate.map { minute($0, zone) } ?? "nil")")
            parts.append("end==start \(event.startDate != nil && event.startDate == event.endDate ? "yes" : "no")")
            parts.append("scheduledDate \(event.scheduledDate.map { minute($0, zone) } ?? "nil")")
            if !event.initialDelivery, let seconds = event.secondsAfterStart {
                parts.append("\(Int(seconds.rounded())) s after start")
            }
        }
        return parts.joined(separator: " | ")
    }

    private static func number(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// `2026-10-10 14:32`, with the seconds dropped, never rounded up.
    static func minute(_ date: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
