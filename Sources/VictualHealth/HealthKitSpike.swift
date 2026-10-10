#if canImport(HealthKit) && compiler(>=6.2)
// `compiler(>=6.2)` stands in for the iOS 26 SDK: HealthKit exists in older SDKs, but the
// medication types do not, and CI's Xcode 16.4 (Swift 6.1) must still build this target.
import CryptoKit
import Foundation
import HealthKit
import Observation

/// Plan 03 Phase 0: runs the HealthKit calls the sync design rests on and records
/// what a device does, **locally, with no network**.
///
/// It reads and observes; it never writes to Health and never talks to a server.
/// What it keeps is shaped by ``SpikeReport``'s types, which have no field for a
/// medication name or nickname. The names it does see (to tell whether
/// `description` embeds one) are compared and dropped, and the only thing saved
/// between launches is a SHA-256 of each reference candidate.
@available(iOS 26, macOS 26, macCatalyst 26, watchOS 26, visionOS 26, *)
@MainActor
@Observable
public final class HealthKitSpike {
    public private(set) var medications: [SpikeMedicationFinding] = []
    /// Names for the on-screen list only, by finding label. Never exported or saved.
    public private(set) var displayNames: [String: String] = [:]
    public private(set) var events: [SpikeEventFinding] = []
    public private(set) var revocations: [SpikeRevocationFinding] = []
    public private(set) var backgroundDelivery: String?
    public private(set) var authorizationRequests = 0
    public private(set) var unknownStatusCount = 0
    public private(set) var isObserving = false
    /// The last thing that went wrong, for the screen.
    public private(set) var lastError: String?

    private let source: HealthKitDoseSource
    private let store: HKHealthStore
    private let previousRunURL: URL?
    private let previousRun: PreviousRun?
    private var labelsByHash: [String: String] = [:]
    private var observation: Task<Void, Never>?
    private var streamAnchor: HKQueryAnchor?
    private var requeryAnchor: HKQueryAnchor?
    private var seenSamples: [String: String] = [:]

    /// - Parameter directory: Where the opaque comparison file lives. `nil` skips
    ///   the across-launches comparison.
    public init(store: HKHealthStore = HKHealthStore(), directory: URL? = nil) {
        self.store = store
        self.source = HealthKitDoseSource(store: store)
        self.previousRunURL = directory?.appendingPathComponent("spike-previous-run.json")
        self.previousRun = directory.flatMap { _ in
            Self.load(directory?.appendingPathComponent("spike-previous-run.json"))
        }
    }

    public var snapshot: SpikeSnapshot {
        SpikeSnapshot(
            environment: .current(), authorizationRequests: authorizationRequests, medications: medications,
            events: events, revocations: revocations, backgroundDelivery: backgroundDelivery,
            unknownStatusCount: unknownStatusCount, generatedAt: Date())
    }

    public func report() -> String { SpikeReport.render(snapshot) }

    // MARK: Actions (each is one explicit tap)

    /// Health's medication sheet. Always prompts, so only ever from a button.
    public func requestAuthorization() async {
        do {
            try await source.requestMedicationAuthorization()
            authorizationRequests += 1
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        await refreshMedications()
    }

    /// Lists the authorized medications and records both reference candidates.
    public func refreshMedications() async {
        do {
            let entries = try await source.annotatedMedications()
            medications = entries.map(finding(for:))
            for entry in entries {
                displayNames[label(for: entry.candidates.hashed)] = entry.displayName
            }
            save(entries)
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Whether Health accepts a background-delivery registration for dose events.
    /// Acceptance is not proof the app is woken; it is the first thing to rule out.
    public func enableBackgroundDelivery() async {
        do {
            try await store.enableBackgroundDelivery(for: HKObjectType.medicationDoseEventType(), frequency: .immediate)
            backgroundDelivery = "accepted"
        } catch {
            backgroundDelivery = "rejected: \(Self.describe(error))"
        }
    }

    /// Starts the anchored query and keeps listening, timestamping each arrival.
    public func startObserving() {
        guard observation == nil else { return }
        isObserving = true
        let descriptor = HealthKitDoseSource.anchoredDescriptor(anchor: nil, since: nil)
        let store = store
        observation = Task { [weak self] in
            var first = true
            do {
                for try await result in descriptor.results(for: store) {
                    let arrived = Date()
                    guard let self else { return }
                    self.ingest(result, arrivedAt: arrived, initial: first)
                    first = false
                }
            } catch {
                self?.lastError = Self.describe(error)
            }
            self?.isObserving = false
            self?.observation = nil
        }
    }

    public func stopObserving() {
        observation?.cancel()
        observation = nil
        isObserving = false
    }

    /// After revoking one medication in the Health app: lists medications again,
    /// reads from the previous anchor, and reads fresh, then records the
    /// difference. Revocation is the case the plan's evidence rule depends on.
    public func requeryAfterRevocation() async {
        let before = Set(medications.map(\.label))
        let beforeCount = medications.count
        await refreshMedications()
        let after = Set(medications.map(\.label))
        do {
            let delta = try await HealthKitDoseSource.anchoredDescriptor(anchor: requeryAnchor ?? streamAnchor, since: nil)
                .result(for: store)
            requeryAnchor = delta.newAnchor
            let fresh = try await HealthKitDoseSource.anchoredDescriptor(anchor: nil, since: nil).result(for: store)
            revocations.append(
                SpikeRevocationFinding(
                    at: Date(), medicationsBefore: beforeCount, medicationsAfter: medications.count,
                    vanished: before.subtracting(after).sorted(), deltaAdded: delta.addedSamples.count,
                    deltaDeleted: delta.deletedObjects.count, freshRead: fresh.addedSamples.count))
            for deleted in delta.deletedObjects {
                events.append(
                    SpikeEventFinding(
                        kind: .deleted, shortID: Self.short(deleted.uuid), arrivedAt: Date(),
                        medicationLabel: seenSamples[deleted.uuid.uuidString], initialDelivery: false))
            }
        } catch {
            lastError = Self.describe(error)
        }
    }

    public func clearEvents() {
        events = []
        revocations = []
    }

    // MARK: Ingest

    private func ingest(_ result: HKAnchoredObjectQueryDescriptor<HKSample>.Result, arrivedAt: Date, initial: Bool) {
        streamAnchor = result.newAnchor
        for sample in result.addedSamples {
            guard let dose = sample as? HKMedicationDoseEvent else { continue }
            guard let candidates = try? HealthKitDoseSource.candidates(for: dose.medicationConceptIdentifier) else {
                lastError = "A dose event's medication identifier would not archive."
                continue
            }
            let medicationLabel = label(for: candidates.hashed)
            seenSamples[dose.uuid.uuidString] = medicationLabel
            guard DoseLogStatus(dose.logStatus) != nil else {
                unknownStatusCount += 1
                continue
            }
            events.append(
                SpikeEventFinding(
                    kind: .inserted, shortID: Self.short(dose.uuid), arrivedAt: arrivedAt,
                    medicationLabel: medicationLabel, status: "\(DoseLogStatus(dose.logStatus)?.rawValue ?? "?")",
                    scheduleType: DoseScheduleType(dose.scheduleType).rawValue, doseQuantity: dose.doseQuantity,
                    scheduledDoseQuantity: dose.scheduledDoseQuantity, unitString: dose.unit.unitString,
                    startDate: dose.startDate, endDate: dose.endDate, scheduledDate: dose.scheduledDate,
                    initialDelivery: initial))
        }
        for deleted in result.deletedObjects {
            events.append(
                SpikeEventFinding(
                    kind: .deleted, shortID: Self.short(deleted.uuid), arrivedAt: arrivedAt,
                    medicationLabel: seenSamples[deleted.uuid.uuidString], initialDelivery: initial))
        }
    }

    // MARK: Findings

    private func label(for hash: String) -> String {
        if let existing = labelsByHash[hash] { return existing }
        let label = "M\(labelsByHash.count + 1)"
        labelsByHash[hash] = label
        return label
    }

    private func finding(for entry: HealthKitDoseSource.AnnotatedEntry) -> SpikeMedicationFinding {
        let identifier = entry.medication.medication.identifier
        let first = HealthKitDoseSource.archive(identifier)
        let second = HealthKitDoseSource.archive(identifier)
        let roundTrip = first
            .flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKHealthConceptIdentifier.self, from: $0) }
            .flatMap { HealthKitDoseSource.archive($0) }
        let name = entry.displayName.lowercased()
        let nickname = (entry.medication.nickname ?? "").lowercased()
        let description = (entry.candidates.description ?? "").lowercased()
        let embedsName = !description.isEmpty
            && ((!name.isEmpty && description.contains(name)) || (!nickname.isEmpty && description.contains(nickname)))
        return SpikeMedicationFinding(
            label: label(for: entry.candidates.hashed),
            candidates: entry.candidates,
            archiveRepeatable: first != nil && first == second,
            archiveRoundTrips: first != nil && first == roundTrip,
            descriptionSeenLastLaunch: previousRun.map { run in
                entry.candidates.description.map { run.descriptionDigests.contains(Self.digest($0)) } ?? false
            },
            hashSeenLastLaunch: previousRun.map { $0.hashDigests.contains(Self.digest(entry.candidates.hashed)) },
            isArchived: entry.medication.isArchived,
            hasSchedule: entry.medication.hasSchedule,
            generalForm: entry.medication.medication.generalForm.rawValue,
            hasNickname: entry.medication.nickname != nil,
            descriptionContainsName: embedsName)
    }

    // MARK: Cross-launch comparison

    /// SHA-256 digests of the candidates last launch saw. A digest, not the
    /// value: a `description` might embed a name, and nothing else needs the text.
    private struct PreviousRun: Codable {
        var descriptionDigests: [String]
        var hashDigests: [String]
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func load(_ url: URL?) -> PreviousRun? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PreviousRun.self, from: data)
    }

    private var savedThisRun = false

    /// Saves this launch's candidates once, so the *next* launch compares against
    /// them and a second tap in the same launch cannot overwrite the baseline.
    private func save(_ entries: [HealthKitDoseSource.AnnotatedEntry]) {
        guard !savedThisRun, let url = previousRunURL, !entries.isEmpty else { return }
        let run = PreviousRun(
            descriptionDigests: entries.compactMap { $0.candidates.description.map(Self.digest) },
            hashDigests: entries.map { Self.digest($0.candidates.hashed) })
        guard let data = try? JSONEncoder().encode(run) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: FileSyncStateStore.writeOptions)
            savedThisRun = true
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: Helpers

    private static func short(_ uuid: UUID) -> String { String(uuid.uuidString.prefix(4)) }

    /// An error's domain and code. Not its message: a `localizedDescription` from
    /// Health could in principle name something.
    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
#endif
