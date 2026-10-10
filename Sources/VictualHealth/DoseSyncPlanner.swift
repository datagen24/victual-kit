import Foundation

/// What one batch did to the queue, for the screen to explain.
struct PlanReport: Equatable {
    /// Medications with events but no approved mapping: nothing was queued for them.
    var needsMapping: Set<String> = []
    /// Medications whose deletions showed the person no longer authorizes them.
    var revoked: Set<String> = []
    /// `notLogged` samples that matched no single sent dose, so nothing was undone.
    var unmatchedUndos = 0
    var queued = 0
}

/// Turns one batch of Health changes into outbox records and ledger updates.
///
/// Pure: no I/O, no clock. Everything it decides is in the plan's field
/// mapping, status translation, `replaces` and deletion-reason tables.
enum DoseSyncPlanner {
    static func apply(
        _ batch: DoseEventBatch,
        to queue: inout SyncQueue,
        mappings: MappingSet,
        availability: [String: MedicationAvailability]?,
        now: Date,
        zone: TimeZone
    ) -> PlanReport {
        var report = PlanReport()
        var takens: [DoseEvent] = []
        var others: [DoseEvent] = []

        for event in batch.inserted {
            guard let mapping = mappings[event.medicationRef] else {
                report.needsMapping.insert(event.medicationRef)
                continue
            }
            // The device-side `effective_from` filter; the server enforces it too.
            guard event.occurredAt >= mapping.effectiveFrom else { continue }
            if event.status == .taken { takens.append(event) } else { others.append(event) }
        }

        // IDs that a status PUT already covers, so a deletion of the same dose
        // is not also sent as a DELETE.
        var handled = Set<String>()

        for event in others {
            let status = ConsumptionStatus(event.status)
            if let entry = queue.ledger[event.id] {
                // Same sample, new status.
                guard entry.state == .taken else { continue }
                retract(entry, as: status, queue: &queue, handled: &handled, now: now, zone: zone, report: &report)
            } else if event.status == .notLogged {
                // A new sample undoing an earlier dose. The server has no row for
                // *this* uuid, so the status must go to the dose it undoes: same
                // medication, and the same scheduled date or the same start. If
                // that is not exactly one dose, guess nothing.
                let matches = queue.ledger.values.filter {
                    $0.state == .taken && !handled.contains($0.id) && $0.medicationRef == event.medicationRef
                        && (($0.scheduledDate != nil && $0.scheduledDate == event.scheduledDate)
                            || $0.occurredAt == event.occurredAt)
                }
                if matches.count == 1, let entry = matches.first {
                    retract(entry, as: status, queue: &queue, handled: &handled, now: now, zone: zone, report: &report)
                } else {
                    report.unmatchedUndos += 1
                }
            }
            // Skipped, snoozed and unanswered for a dose never sent: dropped here,
            // so "no adherence record" does not depend on the server.
        }

        let fresh = takens.filter { event in
            guard let known = queue.ledger[event.id] else { return true }
            return !(known.medicationRef == event.medicationRef && known.quantity == event.quantity
                && known.unit == event.unit && known.occurredAt == event.occurredAt)
        }

        let deletions = batch.deleted.compactMap { queue.ledger[$0] }
            .filter { $0.state == .taken && !handled.contains($0.id) }

        let pairs = replacementPairs(deletions: deletions, insertions: fresh)

        for event in fresh {
            guard let mapping = mappings[event.medicationRef] else { continue }
            let submission = ConsumptionEventSubmission(
                status: .taken,
                medicationRef: event.medicationRef,
                quantity: event.quantity,
                unitLabel: event.unit,
                occurredAt: RFC3339Timestamp(event.occurredAt, in: zone),
                sourceUpdatedAt: RFC3339Timestamp(now, in: zone),
                locationID: mapping.location.mode == .explicit ? mapping.location.locationID : nil,
                replaces: pairs[event.id]
            )
            enqueue(.put(submission), for: event.id, queue: &queue, report: &report)
            queue.ledger[event.id] = LedgerEntry(
                id: event.id, medicationRef: event.medicationRef, occurredAt: event.occurredAt,
                quantity: event.quantity, unit: event.unit, scheduledDate: event.scheduledDate,
                scheduleType: event.scheduleType, state: .taken)
            if let old = pairs[event.id] { queue.ledger[old]?.state = .replaced }
        }

        let replacedIDs = Set(pairs.values)
        for entry in deletions where !replacedIDs.contains(entry.id) {
            let reason = deletionReason(for: entry, availability: availability)
            if reason == .accessRevoked { report.revoked.insert(entry.medicationRef) }
            enqueue(.delete(reason: reason), for: entry.id, queue: &queue, report: &report)
            queue.ledger[entry.id]?.state = .removed
        }
        return report
    }

    /// The only reasons this client can prove. Anything else is omitted, which
    /// the server reads as `unknown` and queues for a person to decide.
    /// `entered_in_error` and `history_cleared` are never returned.
    static func deletionReason(
        for entry: LedgerEntry,
        availability: [String: MedicationAvailability]?
    ) -> DeletionReason? {
        guard let availability else { return nil }
        switch availability[entry.medicationRef] {
        case nil: return .accessRevoked
        case .archived: return .medicationArchived
        case .active: return nil
        }
    }

    /// `old id` by `new id`, only for a deletion and an insertion in one batch
    /// with the same medication and the same non-nil scheduled date, both
    /// `.schedule`, and exactly one of each. Several of either is ambiguous, and
    /// a wrong pairing voids a real dose, so it is not attempted.
    private static func replacementPairs(
        deletions: [LedgerEntry],
        insertions: [DoseEvent]
    ) -> [String: String] {
        struct Key: Hashable {
            var medicationRef: String
            var scheduledDate: Date
        }
        var deleted: [Key: [LedgerEntry]] = [:]
        for entry in deletions where entry.scheduleType == .schedule {
            if let date = entry.scheduledDate {
                deleted[Key(medicationRef: entry.medicationRef, scheduledDate: date), default: []].append(entry)
            }
        }
        var inserted: [Key: [DoseEvent]] = [:]
        for event in insertions where event.scheduleType == .schedule {
            if let date = event.scheduledDate {
                inserted[Key(medicationRef: event.medicationRef, scheduledDate: date), default: []].append(event)
            }
        }
        var pairs: [String: String] = [:]
        for (key, old) in deleted {
            if old.count == 1, let new = inserted[key], new.count == 1 {
                pairs[new[0].id] = old[0].id
            }
        }
        return pairs
    }

    private static func retract(
        _ entry: LedgerEntry,
        as status: ConsumptionStatus,
        queue: inout SyncQueue,
        handled: inout Set<String>,
        now: Date,
        zone: TimeZone,
        report: inout PlanReport
    ) {
        let submission = ConsumptionEventSubmission(
            status: status,
            medicationRef: entry.medicationRef,
            occurredAt: RFC3339Timestamp(entry.occurredAt, in: zone),
            sourceUpdatedAt: RFC3339Timestamp(now, in: zone)
        )
        enqueue(.put(submission), for: entry.id, queue: &queue, report: &report)
        queue.ledger[entry.id]?.state = .retracted
        handled.insert(entry.id)
    }

    private static func enqueue(
        _ operation: OutboxRecord.Operation,
        for eventID: String,
        queue: inout SyncQueue,
        report: inout PlanReport
    ) {
        queue.outbox.append(OutboxRecord(sequence: queue.nextSequence, eventID: eventID, operation: operation))
        queue.nextSequence += 1
        report.queued += 1
    }
}
