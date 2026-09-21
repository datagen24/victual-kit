import Foundation
import OpenAPIRuntime

/// How this package reads and writes the two date shapes Victual puts on the wire.
///
/// The server renders timestamps the way its database stores them — `"2019-05-03
/// 18:24:04"`, a space instead of a `T` and no offset — while the specification
/// types those fields `format: date-time`. A strict ISO 8601 reader rejects them,
/// so `row_created_timestamp` alone would fail every stock-entry read.
/// [ADR-0005](https://github.com/datagen24/victual/blob/master/docs/adr/0005-wire-contract-is-the-invariant.md)
/// documents that rendering as an accepted exception; this is where the package
/// absorbs it, once, so no caller has to.
///
/// Day-only fields (`format: date`) generate as `Swift.String` rather than
/// `Foundation.Date`, so they are parsed here explicitly by ``day(_:)`` at the
/// mapping boundary. They too are tolerated with a `" 00:00:00"` suffix.
///
/// Both readers interpret a zone-less value in
/// `TimeZone.autoupdatingCurrent`. A due date is a household's calendar day, not
/// an instant, so parsing `"2026-01-31"` as UTC and rendering it locally would
/// show the wrong day to anyone west of Greenwich.
public enum VictualDates {
    /// Parses a `format: date` field — a calendar day, as local midnight.
    ///
    /// Accepts `"2026-01-31"` and `"2026-01-31 00:00:00"`, and returns `nil` for
    /// anything else, including the empty string the server sends for "no date".
    public static func day(_ text: String?) -> Date? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return formatters.parse(trimmed, using: dayFormats)
    }

    /// Renders a calendar day as the `YYYY-MM-DD` the API expects in a request body.
    public static func string(fromDay date: Date) -> String {
        formatters.string(from: date, using: "yyyy-MM-dd")
    }

    /// The transcoder ``VictualClient`` installs for every `format: date-time`
    /// field in the specification.
    public static let transcoder: any DateTranscoder = VictualDateTranscoder()

    /// Tried in order. The bare day is last so that a value carrying a time is
    /// never truncated to midnight by an earlier, shorter pattern.
    private static let dayFormats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
    fileprivate static let timestampFormats = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
    ]
    fileprivate static let formatters = FormatterCache()
}

/// A `DateTranscoder` that reads what Victual actually sends and writes ISO 8601.
///
/// Decoding tries ISO 8601 first — with and without fractional seconds — and then
/// the database renderings. Encoding is always ISO 8601: the package sends no
/// `format: date-time` field today, and a strict, unambiguous instant is the right
/// thing to send if it ever does. A day sent in a request body goes through
/// ``VictualDates/string(fromDay:)`` instead, because those fields are strings on
/// the generated side and never reach a transcoder.
struct VictualDateTranscoder: DateTranscoder {
    private let iso8601 = ISO8601DateTranscoder()

    func encode(_ date: Date) throws -> String {
        try iso8601.encode(date)
    }

    func decode(_ string: String) throws -> Date {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let date = VictualDates.formatters.parseISO8601(trimmed) { return date }
        if let date = VictualDates.formatters.parse(trimmed, using: VictualDates.timestampFormats) {
            return date
        }
        let known = VictualDates.timestampFormats.joined(separator: ", ")
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: [],
                debugDescription:
                    "\"\(string)\" is neither an ISO 8601 timestamp nor one of Victual's "
                    + "database renderings (\(known))."
            )
        )
    }
}

/// Reusable formatters behind a lock.
///
/// `DateFormatter` is expensive to build and a stock table parses several dates
/// per row, so they are cached rather than made per call. The lock mirrors what
/// `ISO8601DateTranscoder` does in the runtime, and is what makes this safe to
/// share across the tasks a client is used from.
final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]
    private let iso8601WithFraction: ISO8601DateFormatter
    private let iso8601: ISO8601DateFormatter

    init() {
        iso8601 = ISO8601DateFormatter()
        iso8601WithFraction = ISO8601DateFormatter()
        iso8601WithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parseISO8601(_ text: String) -> Date? {
        lock.withLock {
            iso8601.date(from: text) ?? iso8601WithFraction.date(from: text)
        }
    }

    func parse(_ text: String, using formats: [String]) -> Date? {
        lock.withLock {
            for format in formats {
                if let date = formatter(format).date(from: text) { return date }
            }
            return nil
        }
    }

    func string(from date: Date, using format: String) -> String {
        lock.withLock { formatter(format).string(from: date) }
    }

    /// Must be called with ``lock`` held.
    private func formatter(_ format: String) -> DateFormatter {
        if let existing = cache[format] { return existing }
        let made = DateFormatter()
        // A fixed locale so a user's regional settings cannot change how a wire
        // format parses; an auto-updating zone so a calendar day stays the day
        // the household is living in.
        made.locale = Locale(identifier: "en_US_POSIX")
        made.timeZone = TimeZone.autoupdatingCurrent
        made.dateFormat = format
        cache[format] = made
        return made
    }
}
