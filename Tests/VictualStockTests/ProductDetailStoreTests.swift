import Foundation
import Testing
import VictualCore
import VictualTestSupport

@testable import VictualStock

@Suite("ProductDetailStore")
@MainActor
struct ProductDetailStoreTests {
    private var table: RouteTable {
        var table = RouteTable()
        table.productDetail = """
            {"product": {"id": 7, "name": "Cookies", "qu_id_stock": 3},
             "stock_amount": 3, "stock_amount_opened": 1,
             "next_due_date": "2026-01-31", "last_price": 1.99,
             "quantity_unit_stock": {"id": 3, "name": "Pack", "name_plural": "Packs"},
             "location": {"id": 4, "name": "Kitchen"}}
            """
        table.entries = """
            [{"id": 2, "product_id": 7, "amount": 1, "stock_id": "lot-2",
              "best_before_date": "2026-03-01", "open": 1},
             {"id": 3, "product_id": 7, "amount": 1, "stock_id": "lot-3", "open": 0},
             {"id": 1, "product_id": 7, "amount": 1, "stock_id": "lot-1",
              "best_before_date": "2026-01-31", "open": 0}]
            """
        return table
    }

    @Test("Loads a product and its lots together")
    func loadsDetailAndEntries() async {
        let (client, _) = testClient(table)
        let store = ProductDetailStore(client: client)

        store.select(7)
        await store.waitForLoad()

        #expect(store.state == .loaded)
        #expect(store.detail?.product.name == "Cookies")
        #expect(store.detail?.stockAmount == 3)
        #expect(store.detail?.lastPrice == 1.99)
        #expect(store.detail?.stockQuantityUnit?.namePlural == "Packs")
        #expect(store.entries.count == 3)
    }

    @Test("Lots read soonest due first, with undated ones last")
    func ordersEntriesByDueDate() async {
        let (client, _) = testClient(table)
        let store = ProductDetailStore(client: client)

        store.select(7)
        await store.waitForLoad()

        // An undated lot is not "earliest"; it sinks rather than claiming a place.
        #expect(store.orderedEntries.map { $0.stockID } == ["lot-1", "lot-2", "lot-3"])
    }

    @Test("Clearing the selection empties the inspector")
    func clearsOnNilSelection() async {
        let (client, _) = testClient(table)
        let store = ProductDetailStore(client: client)
        store.select(7)
        await store.waitForLoad()

        store.select(nil)

        #expect(store.detail == nil)
        #expect(store.entries.isEmpty)
        #expect(store.state == .idle)
    }

    @Test("Re-selecting the same product does not refetch")
    func doesNotRefetchSameProduct() async {
        let (client, transport) = testClient(table)
        let store = ProductDetailStore(client: client)
        store.select(7)
        await store.waitForLoad()
        let before = transport.recorder.requests.count

        store.select(7)
        await store.waitForLoad()

        #expect(transport.recorder.requests.count == before)
    }

    @Test("A later selection wins over one still in flight")
    func latestSelectionWins() async {
        let (client, _) = testClient(table)
        let store = ProductDetailStore(client: client)

        store.select(7)
        store.select(9)
        await store.waitForLoad()

        // Whatever the first load would have produced, the inspector is about
        // the row the user actually clicked last.
        #expect(store.productID == 9)
    }

    @Test("A failed load surfaces and keeps the selection")
    func surfacesFailure() async {
        var failing = table
        failing.failures = ["/stock/products/": 404]
        let (client, _) = testClient(failing)
        let store = ProductDetailStore(client: client)

        store.select(7)
        await store.waitForLoad()

        #expect(store.state.error != nil)
        #expect(store.productID == 7)
    }
}

@Suite("ChangePoller")
@MainActor
struct ChangePollerTests {
    @Test("The first read is a baseline, not a change")
    func firstReadIsBaseline() async {
        let (client, _) = testClient()
        let poller = ChangePoller(client: client)

        let moved = await poller.checkNow()

        #expect(!moved)
        #expect(poller.lastChange != nil)
    }

    @Test("An unchanged timestamp reports no change")
    func unchangedReportsNothing() async {
        let (client, _) = testClient()
        let poller = ChangePoller(client: client)
        await poller.checkNow()

        let moved = await poller.checkNow()

        #expect(!moved)
    }

    @Test("A moved timestamp reports a change exactly once")
    func movedReportsOnce() async {
        // Two different timestamps, in the rendering the server actually uses.
        let bodies = ["2026-09-21 09:00:00", "2026-09-21 09:05:00", "2026-09-21 09:05:00"]
        let index = Counter()
        let transport = StubTransport { _, _, _, _ in
            let body = #"{"changed_time":"\#(bodies[min(index.next(), bodies.count - 1)])"}"#
            return (
                .init(status: .ok, headerFields: [.contentType: "application/json"]),
                .init(body)
            )
        }
        let poller = ChangePoller(client: VictualClient.stubbed(transport))

        #expect(await poller.checkNow() == false)  // baseline
        #expect(await poller.checkNow() == true)  // moved
        #expect(await poller.checkNow() == false)  // settled
    }

    @Test("Repeated failures are counted rather than raised every interval")
    func countsFailures() async {
        var table = RouteTable()
        table.failures = ["/system/db-changed-time": 500]
        let (client, _) = testClient(table)
        let poller = ChangePoller(client: client)

        await poller.checkNow()
        await poller.checkNow()

        #expect(poller.consecutiveFailures == 2)
        #expect(poller.error != nil)
        // Polling is an optimisation: manual refresh still works without it.
        #expect(poller.lastChange == nil)
    }

    @Test("A success clears the failure count")
    func successResetsFailures() async {
        let failing = Toggle()
        let transport = StubTransport { _, _, _, _ in
            if failing.isFailing {
                return (.init(status: .init(code: 500)), .init("{}"))
            }
            return (
                .init(status: .ok, headerFields: [.contentType: "application/json"]),
                .init(#"{"changed_time":"2026-09-21 09:00:00"}"#)
            )
        }
        let poller = ChangePoller(client: VictualClient.stubbed(transport))

        failing.isFailing = true
        await poller.checkNow()
        #expect(poller.consecutiveFailures == 1)

        failing.isFailing = false
        await poller.checkNow()

        #expect(poller.consecutiveFailures == 0)
        #expect(poller.error == nil)
    }

    @Test("Stopping an unstarted poller is harmless")
    func stopIsIdempotent() {
        let (client, _) = testClient()
        let poller = ChangePoller(client: client)

        poller.stop()
        poller.stop()

        #expect(!poller.isPolling)
    }
}

/// A call counter usable from the `@Sendable` responder closure.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// A flag usable from the `@Sendable` responder closure.
final class Toggle: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var isFailing: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
