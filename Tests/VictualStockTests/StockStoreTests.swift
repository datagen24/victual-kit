import Foundation
import Testing
import VictualCore
import VictualTestSupport

@testable import VictualStock

@Suite("StockStore")
@MainActor
struct StockStoreTests {
    private var populated: RouteTable {
        var table = RouteTable()
        table.stock = """
            [{"product_id": 7, "amount": 2, "value": 12.5, "best_before_date": "2026-01-31",
              "product": {"id": 7, "name": "Cookies", "qu_id_stock": 3}},
             {"product_id": 9, "amount": 1, "value": 3.0, "best_before_date": "2026-02-10",
              "product": {"id": 9, "name": "Almonds", "qu_id_stock": 4}}]
            """
        table.volatile = """
            {"due_products": [{"product_id": 7, "amount": 2,
                "product": {"id": 7, "name": "Cookies", "qu_id_stock": 3}}],
             "overdue_products": [],
             "expired_products": [],
             "missing_products": [{"id": 9, "name": "Almonds", "amount_missing": 4,
                "is_partly_in_stock": 1}]}
            """
        table.quantityUnits = """
            [{"id": 3, "name": "Pack", "name_plural": "Packs"},
             {"id": 4, "name": "g", "name_plural": "g"}]
            """
        table.locations = #"[{"id": 4, "name": "Kitchen"}, {"id": 9, "name": "Freezer", "parent_location_id": 4}]"#
        table.locationsResolved = """
            [{"descendant_location_id": 4, "depth": 0, "path": "Kitchen"},
             {"descendant_location_id": 9, "depth": 0, "path": "Kitchen / Freezer"}]
            """
        return table
    }

    @Test("Starts empty and idle")
    func startsIdle() {
        let (client, _) = testClient()
        let store = StockStore(client: client)

        #expect(store.state == .idle)
        #expect(store.rows.isEmpty)
    }

    @Test("One refresh answers all five sidebar buckets")
    func refreshFillsEveryBucket() async {
        let (client, transport) = testClient(populated)
        let store = StockStore(client: client)

        await store.refresh()

        #expect(store.state == .loaded)
        #expect(store.count(of: .all) == 2)
        #expect(store.count(of: .dueSoon) == 1)
        #expect(store.count(of: .overdue) == 0)
        #expect(store.count(of: .expired) == 0)
        #expect(store.count(of: .belowMinimum) == 1)
        #expect(store.lastRefreshed != nil)

        // Four requests, not five: `/stock/volatile` answers four buckets.
        let paths = Set(transport.recorder.requests.compactMap { $0.request.path?.split(separator: "?").first.map(String.init) })
        #expect(paths.contains("/stock"))
        #expect(paths.contains("/stock/volatile"))
        #expect(paths.contains("/objects/quantity_units"))
        #expect(paths.contains("/objects/locations"))
    }

    @Test("Rows carry the quantity unit an amount cannot be read without")
    func rowsCarryUnits() async {
        let (client, _) = testClient(populated)
        let store = StockStore(client: client)

        await store.refresh()

        let cookies = store.rows.first { $0.productID == 7 }
        #expect(cookies?.unit?.name == "Pack")
        #expect(cookies?.amountText == "2 Packs")
    }

    @Test("Switching the status scope costs no further request")
    func scopeSwitchIsFree() async {
        let (client, transport) = testClient(populated)
        let store = StockStore(client: client)
        await store.refresh()
        let before = transport.recorder.requests.count

        store.scope = .status(.dueSoon)

        #expect(store.rows.map { $0.name } == ["Cookies"])
        #expect(transport.recorder.requests.count == before)
    }

    @Test("The below-minimum bucket reports how much is short")
    func belowMinimumRows() async {
        let (client, _) = testClient(populated)
        let store = StockStore(client: client)
        await store.refresh()

        store.scope = .status(.belowMinimum)

        let row = store.rows.first
        #expect(row?.name == "Almonds")
        #expect(row?.amountMissing == 4)
    }

    @Test("Search narrows by name, case-insensitively")
    func searchFilters() async {
        let (client, _) = testClient(populated)
        let store = StockStore(client: client)
        await store.refresh()

        store.searchText = "almo"

        #expect(store.rows.map { $0.name } == ["Almonds"])
    }

    @Test("Sorting puts an unknown value last whichever way it points")
    func sortsUnknownsLast() async {
        var table = populated
        // Almonds has no value: the key may not see it, or none was recorded.
        table.stock = """
            [{"product_id": 7, "amount": 2, "value": 12.5, "product": {"id": 7, "name": "Cookies"}},
             {"product_id": 9, "amount": 1, "product": {"id": 9, "name": "Almonds"}}]
            """
        let (client, _) = testClient(table)
        let store = StockStore(client: client)
        await store.refresh()
        store.sort = .value

        store.sortAscending = true
        #expect(store.rows.map { $0.name } == ["Cookies", "Almonds"])

        store.sortAscending = false
        #expect(store.rows.map { $0.name } == ["Cookies", "Almonds"])
    }

    @Test("Locations arrive with the paths the sidebar tree is built from")
    func locationsCarryPaths() async {
        let (client, _) = testClient(populated)
        let store = StockStore(client: client)

        await store.refresh()

        #expect(store.locations.map { $0.name } == ["Kitchen", "Freezer"])
        #expect(store.location(9)?.path == "Kitchen / Freezer")
    }

    @Test("Selecting a location reads what is actually in it")
    func locationScopeFetchesEntries() async {
        var table = populated
        table.locationEntries = """
            [{"id": 1, "product_id": 7, "amount": 2, "price": 1.5, "open": 0,
              "best_before_date": "2026-03-01", "stock_id": "lot-1"},
             {"id": 2, "product_id": 7, "amount": 1, "price": 1.5, "open": 1,
              "best_before_date": "2026-02-01", "stock_id": "lot-2"}]
            """
        let (client, transport) = testClient(table)
        let store = StockStore(client: client)
        await store.refresh()

        store.scope = .location(9)
        await store.waitForLocationFetch()

        let row = try? #require(store.rows.first)
        #expect(store.rows.count == 1)
        #expect(row?.productID == 7)
        // Three units across two lots, one of which is open.
        #expect(row?.amount == 3)
        #expect(row?.amountOpened == 1)
        // Soonest due of the lots present, not the product's overall next due.
        #expect(row?.nextDueDate == VictualDates.day("2026-02-01"))
        // The server's own formula: price times amount, summed.
        #expect(row?.value == 4.5)

        #expect(
            transport.recorder.requests.contains {
                $0.request.path?.hasPrefix("/stock/locations/9/entries") == true
            }
        )
    }

    @Test("A location total goes unknown if any lot in it has no price")
    func locationValueNeedsEveryPrice() async {
        var table = populated
        table.locationEntries = """
            [{"id": 1, "product_id": 7, "amount": 2, "price": 1.5, "open": 0},
             {"id": 2, "product_id": 7, "amount": 1, "open": 0}]
            """
        let (client, _) = testClient(table)
        let store = StockStore(client: client)
        await store.refresh()

        store.scope = .location(9)
        await store.waitForLocationFetch()

        // Summing only the priced lot would understate the total, which is the
        // same mistake as calling a missing price zero.
        #expect(store.rows.first?.value == nil)
        #expect(store.rows.first?.amount == 3)
    }

    @Test("A failed refresh keeps what was already on screen")
    func failureKeepsPreviousRows() async {
        let (client, _) = testClient(populated)
        let store = StockStore(client: client)
        await store.refresh()
        #expect(store.rows.count == 2)

        var failing = populated
        failing.failures = ["/stock": 500]
        let (brokenClient, _) = testClient(failing)
        let broken = StockStore(client: brokenClient)
        await broken.refresh()
        await broken.refresh()

        #expect(broken.state.error != nil)
        // The first store is untouched; the second never had rows to keep.
        #expect(store.rows.count == 2)
    }

    @Test("A refresh failure surfaces as a load error")
    func refreshSurfacesErrors() async {
        var table = populated
        table.failures = ["/stock": 401]
        let (client, _) = testClient(table)
        let store = StockStore(client: client)

        await store.refresh()

        #expect(store.state.error == .unauthorized)
    }
}
