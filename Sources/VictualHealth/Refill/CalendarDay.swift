import Foundation

/// A calendar date with no time and no zone: `2026-03-12`.
///
/// Refill dates are SQL `DATE`s (ADR-0042 §4). Holding them as a ``Date`` would
/// attach a midnight in some zone and invite the off-by-one-day errors the ADR
/// exists to avoid, so the client keeps them as year, month and day, and does day
/// arithmetic in a fixed UTC Gregorian calendar, where there is no daylight saving.
public struct CalendarDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// `nil` unless `text` is exactly `YYYY-MM-DD` and a real date.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            text.allSatisfy({ $0 == "-" || $0.isASCII && $0.isNumber })
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// `nil` for a date that does not exist, such as February 30.
    public init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(calendar: Self.calendar, year: year, month: month, day: day, hour: 12)
        guard let date = Self.calendar.date(from: components),
            Self.calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The calendar date it is in `zone` at `instant`: the person's local "today".
    public init(_ instant: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        self.year = c.year!
        self.month = c.month!
        self.day = c.day!
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Whole days from `self` to `other`; negative when `other` is earlier.
    public func days(until other: CalendarDay) -> Int {
        Self.calendar.dateComponents([.day], from: noon, to: other.noon).day ?? 0
    }

    public func adding(days: Int) -> CalendarDay {
        let date = Self.calendar.date(byAdding: .day, value: days, to: noon)!
        return CalendarDay(date, in: Self.utc)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = CalendarDay(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a calendar date: \(text)"))
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    /// Noon UTC, so that no offset arithmetic can move it across a date line.
    private var noon: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
