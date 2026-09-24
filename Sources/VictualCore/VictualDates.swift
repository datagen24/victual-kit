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
/// ## Which time zone
///
/// The two shapes are read differently on purpose.
///
/// - A **timestamp** without an offset (`"2019-05-03 18:24:04"`) is an instant
///   rendered in the *instance's* configured zone — the server says so in the
///   specification. It is read in ``serverTimeZone`` when the client has learned
///   it from `GET /system/time`, and in the device's zone only until then. A
///   phone in another zone would otherwise shift every such instant by the
///   difference. A timestamp that states its own offset keeps it.
/// - A **day** (`"2026-01-31"`) is a household's calendar day, not an instant.
///   It is read as local midnight in `TimeZone.autoupdatingCurrent`, so the day
///   a due date names is the day shown, wherever the phone is.
public enum VictualDates {
    /// The zone zone-less timestamps are read in, for the duration of one
    /// client operation.
    ///
    /// Bound by ``VictualClient`` around each request it decodes, from what it
    /// learned from `GET /system/time`; `nil` outside one, or before the zone
    /// is known, which falls back to the device's zone. Task-local so that the
    /// runtime's transcoder, the entity-listing decoder and the model mappings
    /// all read the same zone without threading it through every initializer.
    @TaskLocal static var serverTimeZone: TimeZone?

    /// The zone a zone-less timestamp is read in right now: the instance's,
    /// or `nil` for the device's.
    static var timestampZone: TimeZone? { serverTimeZone }

    /// Parses a `format: date` field — a calendar day, as local midnight.
    ///
    /// Accepts `"2026-01-31"` and `"2026-01-31 00:00:00"`, and returns `nil` for
    /// anything else, including the empty string the server sends for "no date".
    public static func day(_ text: String?) -> Date? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return formatters.parse(trimmed, using: dayFormats, in: nil)
    }

    /// Parses a timestamp field — `row_created_timestamp`, `changed_time` and
    /// the like — which since upstream ADR-0027 the specification types as a
    /// plain string rather than `format: date-time`.
    ///
    /// Reads everything ``transcoder`` reads, and additionally the PostgreSQL
    /// `TIMESTAMPTZ` rendering — `"2026-09-01 10:00:00.123456+00"`, a UTC offset
    /// and optional fractional seconds — which ADR-0027 names as an exception
    /// for label fields such as `retired_at`. Fractional seconds are dropped:
    /// nothing here displays or compares below a second. Returns `nil` for an
    /// absent, empty or unreadable value.
    ///
    /// - Parameter timeZone: The zone a value without an offset was rendered
    ///   in — the instance's. Defaults to the one ``VictualClient`` has bound
    ///   for the current operation, or the device's.
    public static func timestamp(_ text: String?, in timeZone: TimeZone? = nil) -> Date? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let zone = timeZone ?? timestampZone
        if let date = VictualDateTranscoder.decode(trimmed, in: zone) { return date }
        let withoutFraction = trimmed.replacingOccurrences(
            of: #"(:\d{2})\.\d+"#, with: "$1", options: .regularExpression)
        // The offset in the text wins over the formatter's zone.
        return formatters.parse(withoutFraction, using: zonedFormats, in: zone)
    }

    /// Renders a calendar day as the `YYYY-MM-DD` the API expects in a request body.
    public static func string(fromDay date: Date) -> String {
        formatters.string(from: date, using: "yyyy-MM-dd", in: nil)
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
    /// PostgreSQL's `TIMESTAMPTZ` output: an offset of `+HH`, or `+HH:MM` for a
    /// zone off the hour.
    private static let zonedFormats = ["yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd HH:mm:ssXXX"]
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
        if let date = Self.decode(trimmed, in: VictualDates.timestampZone) { return date }
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

extension VictualDateTranscoder {
    /// ISO 8601 first — its offset is authoritative — then the database
    /// renderings, which carry none and are read in `timeZone`.
    static func decode(_ trimmed: String, in timeZone: TimeZone?) -> Date? {
        if let date = VictualDates.formatters.parseISO8601(trimmed) { return date }
        return VictualDates.formatters.parse(trimmed, using: VictualDates.timestampFormats, in: timeZone)
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

    func parse(_ text: String, using formats: [String], in timeZone: TimeZone?) -> Date? {
        lock.withLock {
            for format in formats {
                if let date = formatter(format, timeZone).date(from: text) { return date }
            }
            return nil
        }
    }

    func string(from date: Date, using format: String, in timeZone: TimeZone?) -> String {
        lock.withLock { formatter(format, timeZone).string(from: date) }
    }

    /// Must be called with ``lock`` held.
    ///
    /// Keyed by format and zone. `nil` is the device's auto-updating zone, kept
    /// as its own key so a calendar day follows the device if the household
    /// travels.
    private func formatter(_ format: String, _ timeZone: TimeZone?) -> DateFormatter {
        let key = format + "|" + (timeZone?.identifier ?? "device")
        if let existing = cache[key] { return existing }
        let made = DateFormatter()
        // A fixed locale so a user's regional settings cannot change how a wire
        // format parses.
        made.locale = Locale(identifier: "en_US_POSIX")
        made.timeZone = timeZone ?? .autoupdatingCurrent
        made.dateFormat = format
        cache[key] = made
        return made
    }
}
