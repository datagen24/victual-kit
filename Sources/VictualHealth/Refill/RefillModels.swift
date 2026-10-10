import Foundation

/// Where a refill's reorder date came from. The screen always shows it
/// (ADR-0042 §2): a date from an explicit entry, from a rule for this medication,
/// and from the general fallback are different claims.
public enum RefillDateSource: String, Sendable, Equatable, Codable {
    case explicit
    case daysBeforeEnd = "rule:days_before_end"
    case fixedInterval = "rule:fixed_interval"
    case fractionElapsed = "rule:fraction_elapsed"
    case fallback

    /// Plain words for the screen. States where the date came from; never advises.
    public var provenance: String {
        switch self {
        case .explicit: "A date entered for this fill"
        case .daysBeforeEnd, .fixedInterval, .fractionElapsed: "From a rule set for this medication"
        case .fallback: "Estimated from the last fill (general rule)"
        }
    }
}

public enum RefillStatus: String, Sendable, Equatable, Codable {
    case ok, approaching, due, ordered, unknown
}

/// Why no date could be calculated.
public enum RefillUnknownReason: String, Sendable, Equatable, Codable {
    case noFill = "no_fill"
    case invalidRule = "invalid_rule"
    case invalidSupply = "invalid_supply"
    case resultNotAfterFill = "result_not_after_fill"

    public var explanation: String {
        switch self {
        case .noFill: "No fill has been recorded."
        case .invalidRule: "This medication's rule is incomplete."
        case .invalidSupply: "The days supplied are missing or out of range."
        case .resultNotAfterFill: "The calculated date is not after the fill. Set a date or a rule."
        }
    }
}

/// Which side of the server's clock the "today" came from.
public enum RefillAsOfSource: String, Sendable, Equatable, Codable {
    case client
    case serverUTC = "server_utc"
}

/// One prescription's refill state on one day.
///
/// ``recipeName`` is what the person typed and may be a medication name: it is for
/// the screen only and must never reach a notification, a log or a file.
public struct RefillItem: Sendable, Equatable, Identifiable {
    public var recipeID: Int
    public var id: Int { recipeID }
    public var recipeName: String
    public var asOf: CalendarDay
    public var asOfSource: RefillAsOfSource
    public var status: RefillStatus
    public var daysOverdue: Int?
    public var reorderDate: CalendarDay?
    public var warningDate: CalendarDay?
    public var source: RefillDateSource?
    public var unknownReason: RefillUnknownReason?
    public var leadDays: Int?
    public var filledOn: CalendarDay?
    public var suppliedDays: Int?
    public var openOrder: OpenOrder?
    /// Set when this device saw a different reorder date for the recipe earlier, as
    /// after a corrected fill or a changed rule.
    public var correctedFrom: CalendarDay?

    public struct OpenOrder: Sendable, Equatable {
        public var orderedOn: CalendarDay
        public var ageDays: Int
    }

    /// "Due in 3 days", "Due today", "2 days overdue": from the date and the local
    /// day, which is the same arithmetic the server's status used.
    public var countdown: String? {
        guard let reorderDate else { return nil }
        let days = asOf.days(until: reorderDate)
        switch days {
        case 1...: return "Estimated reorder date in \(days) day\(days == 1 ? "" : "s")"
        case 0: return "Estimated reorder date is today"
        default: return "Estimated reorder date was \(-days) day\(days == -1 ? "" : "s") ago"
        }
    }
}

/// A notice the server raised for the caller.
public struct RefillNotice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Codable { case approaching, due }

    /// `<recipe_id>:<kind>:<reorder_date>`: the server's identity, and ours.
    public var key: String
    public var id: String { key }
    public var kind: Kind
    public var recipeID: Int
    public var recipeName: String
    public var reorderDate: CalendarDay
    public var warningDate: CalendarDay?
    public var daysOverdue: Int?
    public var source: RefillDateSource
}

/// A fill in a prescription's history, including voided ones.
public struct RefillFillRecord: Sendable, Equatable, Identifiable {
    public var id: Int
    public var filledOn: CalendarDay
    public var suppliedDays: Int?
    public var isCurrent: Bool
    public var isVoided: Bool
}

// MARK: - Wire shapes
//
// Hand-written decoders, not the generated types: the generator skips a property
// typed `oneOf: [$ref, null]` ("Schema null is not supported"), so the generated
// `RefillState` has no `current_fill` and no `open_order`, which the screen needs.
// Every field is optional, as in the spec, and an unknown enum value decodes to
// `nil` rather than failing the whole list; `RefillItem(wire:)` then decides.

enum RefillAdaptationError: Error { case missing(String) }

struct RefillWire: Decodable {
    struct Estimate: Decodable {
        var reorderDate: String?
        var warningDate: String?
        var source: String?
        var leadDays: Int?
        var reason: String?
        enum CodingKeys: String, CodingKey {
            case reorderDate = "reorder_date", warningDate = "warning_date", source, leadDays = "lead_days", reason
        }
    }
    struct Fill: Decodable {
        var id: Int?
        var filledOn: String?
        var suppliedDays: Int?
        var isCurrent: Bool?
        var voidedAt: String?
        enum CodingKeys: String, CodingKey {
            case id, filledOn = "filled_on", suppliedDays = "supplied_days", isCurrent = "is_current", voidedAt = "voided_at"
        }
    }
    struct Order: Decodable {
        var orderedOn: String?
        var ageDays: Int?
        enum CodingKeys: String, CodingKey { case orderedOn = "ordered_on", ageDays = "age_days" }
    }

    var recipeID: Int?
    var recipeName: String?
    var asOf: String?
    var asOfSource: String?
    var status: String?
    var daysOverdue: Int?
    var currentFill: Fill?
    var estimate: Estimate?
    var openOrder: Order?
    var fills: [Fill]?

    enum CodingKeys: String, CodingKey {
        case recipeID = "recipe_id", recipeName = "recipe_name", asOf = "as_of", asOfSource = "as_of_source", status
        case daysOverdue = "days_overdue", currentFill = "current_fill", estimate, openOrder = "open_order", fills
    }
}

struct RefillListWire: Decodable {
    var refills: [RefillWire]?
}

struct RefillNoticeWire: Decodable {
    var key: String?
    var kind: String?
    var recipeID: Int?
    var recipeName: String?
    var reorderDate: String?
    var warningDate: String?
    var daysOverdue: Int?
    var source: String?
    enum CodingKeys: String, CodingKey {
        case key, kind, recipeID = "recipe_id", recipeName = "recipe_name", reorderDate = "reorder_date"
        case warningDate = "warning_date", daysOverdue = "days_overdue", source
    }
}

struct RefillNoticeListWire: Decodable {
    var notices: [RefillNoticeWire]?
}

extension RefillItem {
    init(wire state: RefillWire) throws {
        guard let id = state.recipeID else { throw RefillAdaptationError.missing("recipe_id") }
        guard let asOf = state.asOf.flatMap(CalendarDay.init) else { throw RefillAdaptationError.missing("as_of") }
        guard let status = state.status.flatMap(RefillStatus.init) else { throw RefillAdaptationError.missing("status") }
        let estimate = state.estimate
        self.init(
            recipeID: id, recipeName: state.recipeName ?? "", asOf: asOf,
            asOfSource: state.asOfSource.flatMap(RefillAsOfSource.init) ?? .serverUTC,
            status: status, daysOverdue: state.daysOverdue,
            reorderDate: estimate?.reorderDate.flatMap(CalendarDay.init),
            warningDate: estimate?.warningDate.flatMap(CalendarDay.init),
            source: estimate?.source.flatMap(RefillDateSource.init),
            unknownReason: estimate?.reason.flatMap(RefillUnknownReason.init),
            leadDays: estimate?.leadDays,
            filledOn: state.currentFill?.filledOn.flatMap(CalendarDay.init),
            suppliedDays: state.currentFill?.suppliedDays,
            openOrder: state.openOrder.flatMap { order in
                guard let day = order.orderedOn.flatMap(CalendarDay.init) else { return nil }
                return OpenOrder(orderedOn: day, ageDays: order.ageDays ?? 0)
            })
    }
}

extension RefillNotice {
    init(wire notice: RefillNoticeWire) throws {
        guard let key = notice.key, Self.isWellFormed(key), let kind = notice.kind.flatMap(Kind.init),
            let recipe = notice.recipeID, let date = notice.reorderDate.flatMap(CalendarDay.init),
            let source = notice.source.flatMap(RefillDateSource.init)
        else { throw RefillAdaptationError.missing("notice") }
        self.init(
            key: key, kind: kind, recipeID: recipe, recipeName: notice.recipeName ?? "", reorderDate: date,
            warningDate: notice.warningDate.flatMap(CalendarDay.init), daysOverdue: notice.daysOverdue, source: source)
    }

    /// The spec's `^\d+:(approaching|due):\d{4}-\d{2}-\d{2}$`.
    static func isWellFormed(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && !parts[0].isEmpty && parts[0].allSatisfy(\.isASCIIDigit)
            && Kind(rawValue: String(parts[1])) != nil && CalendarDay(String(parts[2])) != nil
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

extension RefillFillRecord {
    init?(wire fill: RefillWire.Fill) {
        guard let id = fill.id, let day = fill.filledOn.flatMap(CalendarDay.init) else { return nil }
        self.init(id: id, filledOn: day, suppliedDays: fill.suppliedDays, isCurrent: fill.isCurrent ?? false, isVoided: fill.voidedAt != nil)
    }
}
