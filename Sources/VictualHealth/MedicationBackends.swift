import Foundation
import VictualCore

/// A server that lives in memory, for previews, tests and the debug demo.
///
/// It stores nothing on disk and talks to nothing. Its behaviour is the small part
/// of ADR-0041 the screens need to be clicked through: an event with no mapping is
/// `needs_mapping`, a unit string the mapping has not confirmed is
/// `needs_review` / `unit_unconfirmed` until approved, anything else books. It is
/// not a model of the server; it exists so the UI can be exercised before the
/// routes do.
public actor DemoMedicationBackend: ConsumptionEventSubmitter, ConsumptionMappingService, MappingCatalog {
    private var stored: [String: ConsumptionMapping] = [:]
    private var events: [String: ConsumptionEvent] = [:]
    private var refs: [String: String] = [:]
    private var capabilitiesAnswer: Result<ConsumptionCapabilities, VictualError>

    public init(capabilities: Result<ConsumptionCapabilities, VictualError> = .success(
            .init(contractVersion: 1, features: MedicationSyncStore.requiredFeatures.sorted()))) {
        self.capabilitiesAnswer = capabilities
    }

    /// Whether an event with this id has reached the demo server.
    public func hasEvent(_ id: String) -> Bool { events[id] != nil }

    // MARK: Submitter

    public func put(_ submission: ConsumptionEventSubmission, sourceEventID: String) async throws -> ConsumptionEvent {
        if let ref = submission.medicationRef { refs[sourceEventID] = ref }
        let ref = submission.medicationRef ?? refs[sourceEventID]
        var event = ConsumptionEvent(sourceEventID: sourceEventID, state: .received)
        switch submission.status {
        case .taken:
            if let ref, let mapping = stored[ref] {
                if let label = submission.unitLabel, !mapping.input.unitLabels.contains(label) {
                    event = ConsumptionEvent(
                        sourceEventID: sourceEventID, state: .needsReview, reason: .unitUnconfirmed, unitLabelSeen: label)
                } else {
                    event.state = .booked
                }
            } else {
                event.state = .needsMapping
            }
        case .notLogged:
            event.state = .undone
        case .skipped, .unanswered, .scheduled:
            event.state = .noConsumption
        }
        events[sourceEventID] = event
        return event
    }

    public func delete(sourceEventID: String, reason: DeletionReason?) async throws -> ConsumptionEvent {
        guard events[sourceEventID] != nil else { throw VictualError.notFound }
        var event = events[sourceEventID]!
        if reason == nil || reason == .unknown {
            event.state = .needsReview
            event.reason = .sourceDeleted
        } else {
            event.state = reason == .enteredInError ? .voided : .booked
        }
        events[sourceEventID] = event
        return event
    }

    public func resolve(sourceEventID: String, action: ResolutionAction) async throws -> ConsumptionEvent {
        guard var event = events[sourceEventID] else { throw VictualError.notFound }
        switch action {
        case .approveUnit:
            if let label = event.unitLabelSeen, let ref = refs[sourceEventID], var mapping = stored[ref] {
                mapping.input.unitLabels.append(label)
                stored[ref] = mapping
            }
            event.state = .booked
            event.reason = nil
        case .void: event.state = .voided; event.reason = nil
        case .keep: event.state = .booked; event.reason = nil
        case .dismiss: event.state = .dismissed; event.reason = nil
        case .retry, .rebook, .link: event.state = .booked; event.reason = nil
        }
        events[sourceEventID] = event
        return event
    }

    public func resolve(sourceEventIDs: [String], action: ResolutionAction) async throws -> [BulkResolveOutcome] {
        var outcomes: [BulkResolveOutcome] = []
        for id in sourceEventIDs {
            if let event = try? await resolve(sourceEventID: id, action: action) {
                outcomes.append(BulkResolveOutcome(sourceEventID: id, httpStatus: 200, event: event))
            } else {
                outcomes.append(BulkResolveOutcome(sourceEventID: id, httpStatus: 404, errorMessage: "not found"))
            }
        }
        return outcomes
    }

    public func capabilities() async throws -> ConsumptionCapabilities {
        try capabilitiesAnswer.get()
    }

    // MARK: Mappings

    public func mappings() async throws -> [ConsumptionMapping] {
        stored.values.sorted { $0.medicationRef < $1.medicationRef }
    }

    public func put(_ input: ConsumptionMappingInput, medicationRef: String) async throws -> ConsumptionMapping {
        let mapping = ConsumptionMapping(medicationRef: medicationRef, input: input)
        stored[medicationRef] = mapping
        return mapping
    }

    public func delete(medicationRef: String) async throws {
        stored[medicationRef] = nil
    }

    // MARK: Catalog

    public func products() async throws -> [CatalogItem] {
        [CatalogItem(id: 1, name: "Demo product A"), CatalogItem(id: 2, name: "Demo product B"), CatalogItem(id: 3, name: "Demo product C")]
    }

    public func recipes() async throws -> [CatalogItem] {
        [CatalogItem(id: 1, name: "Demo recipe")]
    }

    public func units(forProduct id: Int) async throws -> [CatalogUnit] {
        [CatalogUnit(id: 1, name: "piece", factorToStockUnit: 1), CatalogUnit(id: 2, name: "box of 30", factorToStockUnit: 30)]
    }

    public func locations(forProduct id: Int?) async throws -> [CatalogLocation] {
        [CatalogLocation(id: 1, name: "Demo organizer 1"), CatalogLocation(id: 2, name: "Demo organizer 2")]
    }
}
