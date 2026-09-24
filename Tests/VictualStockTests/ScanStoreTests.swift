import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VictualTestSupport

@testable import VictualCore
@testable import VictualStock

/// A clock a test can move.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 0)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

private func scanClient() -> (VictualClient, StubTransport) {
    let transport = StubTransport { request, _, _, _ in
        let path = request.path ?? ""
        let (status, body): (Int, String) =
            if path.hasPrefix("/labels/resolve/") {
                (200, #"{"status":"unknown"}"#)
            } else if path == "/stock/products/by-barcode/4006381333931" {
                (200, #"{"product":{"id":7,"name":"Cookies","qu_id_stock":3},"stock_amount":2}"#)
            } else {
                (400, #"{"error_message":"No product with that barcode"}"#)
            }
        return (
            HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]),
            HTTPBody(body)
        )
    }
    return (VictualClient.stubbed(transport), transport)
}

@MainActor
@Suite("Scan store")
struct ScanStoreTests {
    @Test("A scan resolves through the server")
    func resolves() async {
        let (client, _) = scanClient()
        let store = ScanStore(client: client)

        #expect(store.submit("4006381333931"))
        #expect(store.phase == .resolving)
        await store.waitForResolution()

        #expect(store.code == "4006381333931")
        #expect(store.phase.resolution?.product?.id == 7)
    }

    @Test("The same code read again within the window is ignored")
    func debouncesRepeats() async {
        let clock = TestClock()
        let (client, transport) = scanClient()
        let store = ScanStore(client: client, now: { clock.now })

        store.submit("4006381333931")
        await store.waitForResolution()
        let sent = transport.recorder.requests.count

        clock.advance(1)
        #expect(!store.submit("4006381333931"))
        #expect(transport.recorder.requests.count == sent)
    }

    @Test("The window slides while the code stays in frame")
    func windowSlides() async {
        let clock = TestClock()
        let (client, _) = scanClient()
        let store = ScanStore(client: client, now: { clock.now })

        store.submit("4006381333931")
        await store.waitForResolution()
        // Seen again every two seconds: never three seconds apart.
        for _ in 0..<4 {
            clock.advance(2)
            #expect(!store.submit("4006381333931"))
        }
        clock.advance(4)
        #expect(store.submit("4006381333931"))
    }

    @Test("Dismissing a result does not let the package in hand pop it back up")
    func clearKeepsTheWindow() async {
        let clock = TestClock()
        let (client, _) = scanClient()
        let store = ScanStore(client: client, now: { clock.now })

        store.submit("4006381333931")
        await store.waitForResolution()
        clock.advance(10)
        store.clear()
        #expect(store.phase == .idle)

        clock.advance(1)
        #expect(!store.submit("4006381333931"))
    }

    @Test("A deliberate submission skips the window")
    func forceSkipsTheWindow() async {
        let clock = TestClock()
        let (client, _) = scanClient()
        let store = ScanStore(client: client, now: { clock.now })

        store.submit("4006381333931")
        await store.waitForResolution()
        #expect(store.submit("4006381333931", force: true))
    }

    @Test("A different code is looked up at once and supersedes the last")
    func differentCodeSupersedes() async {
        let (client, _) = scanClient()
        let store = ScanStore(client: client)

        store.submit("4006381333931")
        store.submit("999")
        await store.waitForResolution()

        #expect(store.code == "999")
        #expect(store.phase == .resolved(.unknown))
    }

    @Test("Blank input is not a scan")
    func ignoresBlank() {
        let (client, transport) = scanClient()
        let store = ScanStore(client: client)

        #expect(!store.submit("  \n"))
        #expect(store.phase == .idle)
        #expect(transport.recorder.requests.isEmpty)
    }

    @Test("A failure is reported against the code that caused it")
    func reportsFailure() async {
        let store = ScanStore(client: VictualClient.stubbed(.failing()))

        store.submit("4006381333931")
        await store.waitForResolution()

        #expect(store.code == "4006381333931")
        #expect(store.phase.error?.isRetryable == true)
    }
}
