import Foundation
import HTTPTypes
import OpenAPIRuntime
import VictualCore
import VictualTestSupport

/// A transport that answers each route from a table, so a store's four
/// concurrent requests can each get the body they expect.
///
/// A store fetches stock, volatile stock, quantity units and locations at once;
/// answering all four with one body would only prove that three of them failed
/// to decode.
struct RouteTable: Sendable {
    var stock = "[]"
    var volatile = #"{"due_products":[],"overdue_products":[],"expired_products":[],"missing_products":[]}"#
    var quantityUnits = "[]"
    var locations = "[]"
    var locationsResolved = "[]"
    var productDetail = #"{"product":{"id":7,"name":"Cookies","qu_id_stock":3},"stock_amount":2}"#
    var entries = "[]"
    var locationEntries = "[]"
    var changedTime = #"{"changed_time":"2026-09-21 09:00:00"}"#
    var booking = #"[{"id":1,"product_id":7,"amount":-1,"transaction_id":"tx-1","transaction_type":"consume"}]"#
    var capabilities = #"{"key_type":"default","read_only":false,"permissions":["STOCK_VIEW","STOCK_CONSUME","STOCK_PURCHASE","STOCK_OPEN","STOCK_INVENTORY","STOCK_TRANSFER","STOCK_PRICES_VIEW"]}"#

    /// Routes that should answer a status other than 200.
    var failures: [String: Int] = [:]

    func body(for path: String) -> String {
        if path.hasPrefix("/objects/quantity_units") { return quantityUnits }
        if path.hasPrefix("/objects/locations_resolved") { return locationsResolved }
        if path.hasPrefix("/objects/locations") { return locations }
        if path.hasPrefix("/stock/volatile") { return volatile }
        if path.hasPrefix("/stock/locations/") { return locationEntries }
        if path.contains("/entries") { return entries }
        if path.hasPrefix("/stock/products/") { return isBooking(path) ? booking : productDetail }
        if path.hasPrefix("/stock/transactions/") { return "" }
        if path.hasPrefix("/user/capabilities") { return capabilities }
        if path.hasPrefix("/system/db-changed-time") { return changedTime }
        if path.hasPrefix("/stock") { return stock }
        return "{}"
    }

    private func isBooking(_ path: String) -> Bool {
        ["/consume", "/add", "/open", "/inventory", "/transfer"].contains {
            path.hasSuffix($0)
        }
    }

    func status(for path: String) -> Int {
        for (prefix, code) in failures where path.hasPrefix(prefix) { return code }
        return 200
    }
}

extension StubTransport {
    /// A transport answering from `table`, keyed by the request's path.
    static func routed(_ table: RouteTable) -> StubTransport {
        StubTransport { request, _, _, _ in
            let path = request.path ?? ""
            let status = table.status(for: path)
            if path.hasPrefix("/stock/transactions/"), status == 200 {
                return (HTTPResponse(status: .noContent), nil)
            }
            return (
                HTTPResponse(
                    status: .init(code: status),
                    headerFields: [.contentType: "application/json"]
                ),
                HTTPBody(status == 200 ? table.body(for: path) : #"{"error_message":"no"}"#)
            )
        }
    }
}

func testClient(_ table: RouteTable = RouteTable()) -> (VictualClient, StubTransport) {
    let transport = StubTransport.routed(table)
    return (VictualClient.stubbed(transport), transport)
}
