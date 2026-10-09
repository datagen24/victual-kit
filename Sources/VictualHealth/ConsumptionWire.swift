import Foundation
import VictualCore

// Hand-written to match ADR-0041's `.devtools/adr0041/consumption-events.openapi.json`
// (design fragment, Proposed). The routes are not in `victual.openapi.json` yet, so
// nothing is generated; these are replaced, not wrapped, when #700 lands them.

/// An RFC 3339 timestamp that remembers the text it was built from.
///
/// A payload that is replayed must be byte-identical, and re-rendering a `Date`
/// in whatever offset the device has *now* would change the text. Holding the
/// text keeps a stored request exactly as first written.
public struct RFC3339Timestamp: Sendable, Equatable, Codable {
    public let date: Date
    public let text: String

    /// Renders `date` with the offset of `zone`, to the second.
    public init(_ date: Date, in zone: TimeZone) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = zone
        self.date = date
        self.text = formatter.string(from: date)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let date = VictualDates.timestamp(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not an RFC 3339 timestamp: \(text)"))
        }
        self.date = date
        self.text = text
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// `ConsumptionEventSubmission.status`.
public enum ConsumptionStatus: String, CaseIterable, Sendable, Codable {
    case taken
    case notLogged = "not_logged"
    case skipped
    case unanswered
    case scheduled

    /// Translates Health's status. Only `taken` books; `notLogged` is a person
    /// undoing a prior dose; the reminder states never consume.
    public init(_ status: DoseLogStatus) {
        switch status {
        case .taken: self = .taken
        case .skipped: self = .skipped
        case .notInteracted, .notificationNotSent: self = .unanswered
        case .snoozed: self = .scheduled
        case .notLogged: self = .notLogged
        }
    }
}

/// The body of `PUT /consumption/events/{source_system}/{source_event_id}`.
///
/// Optional fields are omitted when `nil`, never sent as `null`: in particular a
/// dose Health recorded without a quantity has no `quantity` key, and the
/// mapping's `default_quantity` applies server-side.
public struct ConsumptionEventSubmission: Sendable, Equatable, Codable {
    public var status: ConsumptionStatus
    public var medicationRef: String?
    public var quantity: Double?
    public var unitLabel: String?
    public var occurredAt: RFC3339Timestamp?
    public var sourceUpdatedAt: RFC3339Timestamp?
    public var locationID: Int?
    public var replaces: String?

    public init(
        status: ConsumptionStatus,
        medicationRef: String? = nil,
        quantity: Double? = nil,
        unitLabel: String? = nil,
        occurredAt: RFC3339Timestamp? = nil,
        sourceUpdatedAt: RFC3339Timestamp? = nil,
        locationID: Int? = nil,
        replaces: String? = nil
    ) {
        self.status = status
        self.medicationRef = medicationRef
        self.quantity = quantity
        self.unitLabel = unitLabel
        self.occurredAt = occurredAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.locationID = locationID
        self.replaces = replaces
    }

    enum CodingKeys: String, CodingKey {
        case status
        case medicationRef = "medication_ref"
        case quantity
        case unitLabel = "unit_label"
        case occurredAt = "occurred_at"
        case sourceUpdatedAt = "source_updated_at"
        case locationID = "location_id"
        case replaces
    }

    /// The bytes a request carries. Sorted keys, so the same value always
    /// encodes to the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// The `reason` query parameter of `DELETE`.
///
/// ``enteredInError``, ``historyCleared`` and ``unknown`` exist because the
/// server accepts them. This client never sends them: it cannot prove a mistaken
/// log, cannot tell cleared history from many deletions, and says nothing rather
/// than `unknown`.
public enum DeletionReason: String, CaseIterable, Sendable, Codable {
    case enteredInError = "entered_in_error"
    case historyCleared = "history_cleared"
    case medicationArchived = "medication_archived"
    case accessRevoked = "access_revoked"
    case unknown
}

public enum ConsumptionEventState: String, CaseIterable, Sendable, Codable {
    case received
    case needsMapping = "needs_mapping"
    case needsReview = "needs_review"
    case booked
    case undone
    case voided
    case linked
    case dismissed
    case noConsumption = "no_consumption"
}

/// Why an event is `needs_review`. Shown to the person as the server sent it.
public enum ConsumptionReviewReason: String, CaseIterable, Sendable, Codable {
    case ambiguousLocation = "ambiguous_location"
    case insufficientStock = "insufficient_stock"
    case unitUnconfirmed = "unit_unconfirmed"
    case quantityMissing = "quantity_missing"
    case recipeUnavailable = "recipe_unavailable"
    case partiallyUndone = "partially_undone"
    case changedAfterUndo = "changed_after_undo"
    case undoRefused = "undo_refused"
    case invalidMapping = "invalid_mapping"
    case sourceDeleted = "source_deleted"
}

/// A server event, as `PUT`, `GET`, `DELETE` and `resolve` return it.
public struct ConsumptionEvent: Sendable, Equatable, Codable {
    public struct Line: Sendable, Equatable, Codable {
        public var productID: Int?
        public var amount: Double?
        public var locationID: Int?
        public var usedDate: String?

        enum CodingKeys: String, CodingKey {
            case productID = "product_id"
            case amount
            case locationID = "location_id"
            case usedDate = "used_date"
        }
    }

    public struct PossibleDuplicate: Sendable, Equatable, Codable {
        public var transactionID: String?
        public var occurredAt: RFC3339Timestamp?

        enum CodingKeys: String, CodingKey {
            case transactionID = "transaction_id"
            case occurredAt = "occurred_at"
        }
    }

    public var sourceSystem: String
    public var sourceEventID: String
    public var state: ConsumptionEventState
    public var reason: ConsumptionReviewReason?
    public var replayed: Bool?
    public var stale: Bool?
    public var revision: Int?
    public var transactionID: String?
    public var occurredAt: RFC3339Timestamp?
    public var sourceUpdatedAt: RFC3339Timestamp?
    public var lines: [Line]?
    public var candidateLocationIDs: [Int]?
    public var possibleDuplicates: [PossibleDuplicate]?
    public var sourceRemovedAt: RFC3339Timestamp?
    public var sourceRemovedReason: String?
    /// The exact unit string Health sent, for `unit_unconfirmed`.
    public var unitLabelSeen: String?

    public init(
        sourceSystem: String = VictualHealth.sourceSystem,
        sourceEventID: String,
        state: ConsumptionEventState,
        reason: ConsumptionReviewReason? = nil,
        possibleDuplicates: [PossibleDuplicate]? = nil,
        unitLabelSeen: String? = nil
    ) {
        self.sourceSystem = sourceSystem
        self.sourceEventID = sourceEventID
        self.state = state
        self.reason = reason
        self.possibleDuplicates = possibleDuplicates
        self.unitLabelSeen = unitLabelSeen
    }

    enum CodingKeys: String, CodingKey {
        case sourceSystem = "source_system"
        case sourceEventID = "source_event_id"
        case state, reason, replayed, stale, revision
        case transactionID = "transaction_id"
        case occurredAt = "occurred_at"
        case sourceUpdatedAt = "source_updated_at"
        case lines
        case candidateLocationIDs = "candidate_location_ids"
        case possibleDuplicates = "possible_duplicates"
        case sourceRemovedAt = "source_removed_at"
        case sourceRemovedReason = "source_removed_reason"
        case unitLabelSeen = "unit_label_seen"
    }
}

/// An error body: `{error_message, error}`.
public struct ConsumptionErrorBody: Sendable, Equatable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case invalidRequest = "invalid_request"
        case notFound = "not_found"
        case sameVersionDifferentPayload = "same_version_different_payload"
        case invalidTransition = "invalid_transition"
        case invalidMapping = "invalid_mapping"
        case futureOccurredAt = "future_occurred_at"
    }

    public var errorMessage: String
    public var error: Kind?

    enum CodingKeys: String, CodingKey {
        case errorMessage = "error_message"
        case error
    }
}

/// `POST .../resolve` actions.
public enum ResolutionAction: String, CaseIterable, Sendable, Codable {
    case retry, rebook, dismiss, link
    case approveUnit = "approve_unit"
    case void, keep
}

/// `GET /consumption/capabilities`.
public struct ConsumptionCapabilities: Sendable, Equatable, Codable {
    public var contractVersion: Int
    public var features: [String]

    public init(contractVersion: Int, features: [String]) {
        self.contractVersion = contractVersion
        self.features = features
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case features
    }
}

/// How events reach the server.
///
/// A protocol rather than a `VictualClient` extension: `VictualClient` does not
/// expose its transport outside `VictualCore`, and the routes are not in the
/// generated client until #700. The real submitter is Phase 3. A `404` from
/// `capabilities()` is `VictualError.notFound`, an older server.
public protocol ConsumptionEventSubmitter: Sendable {
    /// `PUT`. Identity is in the path, so a retry of identical bytes is safe.
    func put(_ submission: ConsumptionEventSubmission, sourceEventID: String) async throws -> ConsumptionEvent
    /// `DELETE`, with `reason` only when the client can justify one.
    func delete(sourceEventID: String, reason: DeletionReason?) async throws -> ConsumptionEvent
    func resolve(sourceEventID: String, action: ResolutionAction) async throws -> ConsumptionEvent
    func capabilities() async throws -> ConsumptionCapabilities
}
