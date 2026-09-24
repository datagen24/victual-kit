import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualTestSupport

@testable import VictualCore

/// Zone-less timestamps are the instance's local time, and must be read as such.
///
/// A phone in another zone than its server — travelling, or a server set to
/// UTC — would otherwise shift every such instant by the difference.
@Suite("Server time zone")
struct ServerTimeZoneTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// 2026-09-01 08:00:00 UTC, which is 10:00 in Berlin (CEST, UTC+2).
    private let tenInBerlin = Date(timeIntervalSince1970: 1_788_249_600)

    @Test("A zone-less timestamp is read in the zone it was rendered in")
    func zonelessUsesGivenZone() {
        #expect(VictualDates.timestamp("2026-09-01 10:00:00", in: berlin) == tenInBerlin)
    }

    @Test("A timestamp that states its offset keeps it, whatever the server's zone")
    func explicitOffsetWins() {
        let tenUTC = Date(timeIntervalSince1970: 1_788_256_800)
        #expect(VictualDates.timestamp("2026-09-01 10:00:00+00", in: berlin) == tenUTC)
        #expect(VictualDates.timestamp("2026-09-01T10:00:00Z", in: berlin) == tenUTC)
    }

    @Test("A client reads timestamps in the instance's zone")
    func clientBindsItsZone() async throws {
        let body = """
            [{"id": 77, "stock_id": "lot-77", "product_id": 7, "amount": 1,
              "best_before_date": "2026-01-31",
              "row_created_timestamp": "2026-09-01 10:00:00"}]
            """
        let client = VictualClient(
            server: VictualServer(instanceURL: URL(string: "https://victual.test")!),
            apiKey: "test-key",
            transport: StubTransport(status: 200, json: body),
            serverTimeZone: berlin
        )

        let entry = try #require(try await client.stockEntries(productID: 7).first)

        #expect(entry.createdAt == tenInBerlin)
        // A calendar day is not an instant: it stays the device's local
        // midnight however the server's zone is set.
        let day = try #require(entry.bestBeforeDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: day)
        #expect(parts.year == 2026 && parts.month == 1 && parts.day == 31 && parts.hour == 0)
    }

    @Test("Connecting learns the zone from GET /system/time, for every copy of the client")
    func verifyLearnsZone() async throws {
        let transport = StubTransport { request, _, _, _ in
            let body =
                request.path == "/system/time"
                ? #"{"timezone":"Europe/Berlin","time_local":"2026-09-01 10:00:00"}"#
                : systemInfoJSON
            return (
                HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                HTTPBody(body)
            )
        }
        let client = VictualClient.stubbed(transport)
        let copy = client

        _ = try await client.verifyConnection()

        #expect(client.serverTimeZone == berlin)
        #expect(copy.serverTimeZone == berlin)
    }

    @Test("Failing to learn the zone does not fail the connection")
    func zoneIsBestEffort() async throws {
        let transport = StubTransport { request, _, _, _ in
            if request.path == "/system/time" {
                return (HTTPResponse(status: .internalServerError), HTTPBody("{}"))
            }
            return (
                HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                HTTPBody(systemInfoJSON)
            )
        }
        let client = VictualClient.stubbed(transport)

        let information = try await client.verifyConnection()

        #expect(information.victualVersion == "4.2.0")
        #expect(client.serverTimeZone == nil)
    }

    @Test("A stalled time-zone lookup does not hold up a successful connection")
    func stalledLookupIsBounded() async throws {
        let transport = StubTransport { request, _, _, _ in
            if request.path == "/system/time" {
                // Long enough to notice, short enough not to slow the suite.
                try await Task.sleep(for: .milliseconds(600))
                return (
                    HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                    HTTPBody(#"{"timezone":"Europe/Berlin"}"#)
                )
            }
            return (
                HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                HTTPBody(systemInfoJSON)
            )
        }
        let client = VictualClient.stubbed(transport)
        let clock = ContinuousClock()

        let started = clock.now
        _ = try await client.verifyConnection(timeZoneGracePeriod: .milliseconds(100))

        #expect(clock.now - started < .milliseconds(500))
        #expect(client.serverTimeZone == nil)

        // Left running rather than cancelled, it still arrives.
        try await Task.sleep(for: .milliseconds(900))
        #expect(client.serverTimeZone == berlin)
    }

    @Test("A zone Foundation does not know is not remembered")
    func unknownZoneIgnored() async throws {
        let client = VictualClient.stubbed(
            StubTransport(status: 200, json: #"{"timezone":"Mars/Olympus_Mons"}"#))

        let zone = try await client.loadServerTimeZone()

        #expect(zone == nil)
        #expect(client.serverTimeZone == nil)
    }
}
