import Testing

@testable import VictualStock

@Suite("StockFilter")
struct StockFilterTests {
    @Test("Every case has a distinct identifier")
    func identifiersAreDistinct() {
        let ids = Set(StockFilter.allCases.map(\.id))
        #expect(ids.count == StockFilter.allCases.count)
    }

    @Test("Only the unfiltered case is served by GET /stock")
    func volatileCasesAreEverythingButAll() {
        #expect(StockFilter.all.isVolatile == false)
        let volatile = StockFilter.allCases.filter(\.isVolatile)
        #expect(volatile == [.dueSoon, .overdue, .expired, .belowMinimum])
    }
}
