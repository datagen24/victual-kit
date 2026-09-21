import Foundation
import Testing
import VictualCore
import VictualTestSupport

@testable import VictualStock

@Suite("BookingController")
@MainActor
struct BookingControllerTests {
    @Test("A successful booking holds its transaction for undo")
    func holdsUndoAffordance() async {
        let (client, _) = testClient()
        let controller = BookingController(client: client)

        let ok = await controller.perform(.consume(productID: 7, amount: 1))

        #expect(ok)
        #expect(controller.lastAction == .consume)
        #expect(controller.lastBooking?.transactionID == "tx-1")
        #expect(controller.canUndoLast)
        #expect(controller.error == nil)
        #expect(!controller.isWorking)
    }

    @Test("Undo addresses the transaction and withdraws the affordance")
    func undoesTheTransaction() async {
        let (client, transport) = testClient()
        let controller = BookingController(client: client)
        await controller.perform(.consume(productID: 7, amount: 1))

        let ok = await controller.undoLast()

        #expect(ok)
        #expect(!controller.canUndoLast)
        #expect(controller.lastBooking == nil)
        #expect(
            transport.recorder.requests.contains {
                $0.request.path == "/stock/transactions/tx-1/undo"
            }
        )
    }

    @Test("A booking the server returned without a transaction is not undoable")
    func withoutTransactionNoUndo() async {
        var table = RouteTable()
        table.booking = #"[{"id":1,"product_id":7,"amount":-1}]"#
        let (client, _) = testClient(table)
        let controller = BookingController(client: client)

        await controller.perform(.consume(productID: 7, amount: 1))

        #expect(controller.lastBooking != nil)
        #expect(!controller.canUndoLast)
    }

    @Test("Undo with nothing to undo does nothing and sends no request")
    func undoWithoutBooking() async {
        let (client, transport) = testClient()
        let controller = BookingController(client: client)

        let ok = await controller.undoLast()

        #expect(!ok)
        #expect(transport.recorder.requests.isEmpty)
    }

    @Test("A 403 on a write is surfaced, not swallowed")
    func surfacesForbidden() async {
        var table = RouteTable()
        table.failures = ["/stock/products/": 403]
        let (client, _) = testClient(table)
        let controller = BookingController(client: client)

        let ok = await controller.perform(.consume(productID: 7, amount: 1))

        // Capabilities can only say what was true when they were last read; the
        // 403 is the authority and has to reach the user.
        #expect(!ok)
        #expect(controller.error == .forbidden)
        #expect(!controller.canUndoLast)
    }

    @Test("A failed undo withdraws the affordance rather than inviting a retry")
    func failedUndoWithdrawsAffordance() async {
        var table = RouteTable()
        let (client, _) = testClient(table)
        let controller = BookingController(client: client)
        await controller.perform(.consume(productID: 7, amount: 1))

        table.failures = ["/stock/transactions/": 400]
        let (failingClient, _) = testClient(table)
        let failing = BookingController(client: failingClient)
        await failing.perform(.consume(productID: 7, amount: 1))
        let ok = await failing.undoLast()

        #expect(!ok)
        #expect(failing.error != nil)
        #expect(!failing.canUndoLast)
        #expect(controller.canUndoLast)
    }

    @Test("A locally-refused booking never reaches the server")
    func refusesLocallyInvalidBooking() async {
        let (client, transport) = testClient()
        let controller = BookingController(client: client)

        let ok = await controller.perform(
            .consume(productID: 7, amount: 3, stockEntryID: "lot-1")
        )

        #expect(!ok)
        #expect(controller.error != nil)
        #expect(transport.recorder.requests.isEmpty)
    }

    @Test("Every request knows which action and product it is about")
    func requestsDescribeThemselves() {
        let requests: [BookingRequest] = [
            .consume(productID: 7, amount: 1),
            .purchase(productID: 7, amount: 1),
            .open(productID: 7, amount: 1),
            .inventory(productID: 7, newAmount: 1),
            .transfer(productID: 7, amount: 1, fromLocationID: 1, toLocationID: 2),
        ]

        #expect(requests.map { $0.action } == StockAction.allCases)
        #expect(requests.allSatisfy { $0.productID == 7 })
    }

    @Test("Each action names the permission a tooltip has to report")
    func actionsNameTheirPermission() {
        #expect(StockAction.consume.permission == "STOCK_CONSUME")
        #expect(StockAction.purchase.permission == "STOCK_PURCHASE")
        #expect(StockAction.open.permission == "STOCK_OPEN")
        #expect(StockAction.inventory.permission == "STOCK_INVENTORY")
        #expect(StockAction.transfer.permission == "STOCK_TRANSFER")
    }
}

@Suite("CapabilityGate")
@MainActor
struct CapabilityGateTests {
    @Test("Every gate is open before the server has answered")
    func optimisticBeforeLoad() {
        let (client, _) = testClient()
        let gate = CapabilityGate(client: client)

        // A control offered and then refused is a better failure than every
        // control greyed out, wrongly, for the moment after launch.
        #expect(gate.canConsume)
        #expect(gate.canSeePrices)
        #expect(!gate.isReadOnlyKey)
        #expect(gate.reason(.consume) == nil)
    }

    @Test("A full key opens every gate")
    func fullKey() async {
        let (client, _) = testClient()
        let gate = CapabilityGate(client: client)

        await gate.load()

        #expect(gate.state == .loaded)
        #expect(StockAction.allCases.allSatisfy { gate.canWrite($0) })
        #expect(gate.canSeePrices)
        #expect(gate.canUndo)
    }

    @Test("A read-only key closes every write and says so")
    func readOnlyKey() async {
        var table = RouteTable()
        table.capabilities = """
            {"key_type": "mcp", "read_only": true,
             "permissions": ["STOCK_VIEW", "STOCK_CONSUME", "STOCK_PRICES_VIEW"]}
            """
        let (client, _) = testClient(table)
        let gate = CapabilityGate(client: client)

        await gate.load()

        #expect(gate.isReadOnlyKey)
        #expect(!gate.canConsume)
        #expect(!gate.canUndo)
        // Still allowed to look at prices: read-only restricts writing, not
        // reading.
        #expect(gate.canSeePrices)
        let reason = gate.reason(.consume)
        #expect(reason?.contains("read-only") == true)
    }

    @Test("A missing permission is named in the reason, not just refused")
    func namesTheMissingPermission() async {
        var table = RouteTable()
        table.capabilities = #"{"key_type":"default","read_only":false,"permissions":["STOCK_VIEW"]}"#
        let (client, _) = testClient(table)
        let gate = CapabilityGate(client: client)

        await gate.load()

        #expect(!gate.canConsume)
        #expect(gate.reason(.consume)?.contains("STOCK_CONSUME") == true)
        #expect(!gate.canSeePrices)
    }

    @Test("An administrator is not locked out by an unexpanded permission list")
    func adminIsHonoured() async {
        var table = RouteTable()
        table.capabilities = #"{"key_type":"default","read_only":false,"permissions":["ADMIN"]}"#
        let (client, _) = testClient(table)
        let gate = CapabilityGate(client: client)

        await gate.load()

        #expect(StockAction.allCases.allSatisfy { gate.canWrite($0) })
        #expect(gate.canSeePrices)
    }

    /// Not hypothetical: a Victual 4.6.0 instance (migration 286) serves no
    /// `/user/capabilities` at all, because the route arrived with upstream
    /// `5995cab`. An older server must degrade to "ask the server" rather than
    /// to "refuse everything".
    @Test("A server too old to have the endpoint does not lock the user out")
    func toleratesAServerWithoutTheEndpoint() async {
        var table = RouteTable()
        table.failures = ["/user/capabilities": 404]
        let (client, _) = testClient(table)
        let gate = CapabilityGate(client: client)

        await gate.load()

        #expect(gate.state.error == .notFound)
        #expect(gate.capabilities == nil)
        #expect(StockAction.allCases.allSatisfy { gate.canWrite($0) })
        #expect(gate.canSeePrices)
        #expect(!gate.isReadOnlyKey)
        // Nothing to name as an obstacle, because nothing is known to be one.
        #expect(gate.reason(.consume) == nil)
    }

    @Test("A failed capability fetch leaves the gates open and records why")
    func failureIsNotALockout() async {
        var table = RouteTable()
        table.failures = ["/user/capabilities": 500]
        let (client, _) = testClient(table)
        let gate = CapabilityGate(client: client)

        await gate.load()

        #expect(gate.state.error != nil)
        // Not knowing what a key may do is not a reason to lock a household out
        // of its own stock. The server remains the backstop.
        #expect(gate.canConsume)
    }
}
