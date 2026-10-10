import Foundation
import Testing
@testable import VictualHealth

@Suite("Status translation and mapping")
struct MappingAndStatusTests {
    @Test(arguments: [
        (DoseLogStatus.taken, ConsumptionStatus.taken),
        (.skipped, .skipped),
        (.notInteracted, .unanswered),
        (.notificationNotSent, .unanswered),
        (.snoozed, .scheduled),
        (.notLogged, .notLogged),
    ])
    func translation(source: DoseLogStatus, wire: ConsumptionStatus) {
        #expect(ConsumptionStatus(source) == wire)
    }

    @Test func everyHealthStatusTranslates() {
        // Adding a case to DoseLogStatus must fail to compile in the initializer; this
        // documents that only `taken` can book.
        let booking = DoseLogStatus.allCases.filter { ConsumptionStatus($0) == .taken }
        #expect(booking == [.taken])
    }

    @Test func mappingSetIDMovesWithWhatIsReadAndWhereItBooks() {
        let base = MappingSet([Fixtures.mapping()])
        #expect(base.id == MappingSet([Fixtures.mapping()]).id)
        #expect(base.id != MappingSet([Fixtures.mapping(effectiveFrom: Fixtures.t0)]).id)
        #expect(base.id != MappingSet([Fixtures.mapping(location: .init(mode: .fixed, locationID: 10))]).id)
        #expect(base.id != MappingSet([Fixtures.mapping(), Fixtures.mapping("hk:med:43")]).id)
    }

    @Test func mappingSetIDDoesNotDependOnInsertionOrder() {
        let a = Fixtures.mapping("hk:med:1"), b = Fixtures.mapping("hk:med:2")
        #expect(MappingSet([a, b]).id == MappingSet([b, a]).id)
    }
}
