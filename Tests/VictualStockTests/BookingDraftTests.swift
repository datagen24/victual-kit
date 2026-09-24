import Foundation
import Testing

@testable import VictualCore
@testable import VictualStock

@Suite("Booking draft")
struct BookingDraftTests {
    private let product = ProductDetail(
        product: ProductSummary(id: 7, name: "Cookies"),
        stockAmount: 4,
        nextDueDate: Date(timeIntervalSinceReferenceDate: 1_000),
        location: StorageLocation(id: 2, name: "Pantry")
    )

    @Test("Most bookings start by moving one")
    func movesOne() {
        for action in [StockAction.consume, .purchase, .open, .transfer] {
            #expect(BookingDraft(action: action, productID: 7, product: product).amount == 1)
        }
    }

    @Test("An inventory starts from what the server says is there")
    func inventoryStartsFromStock() {
        #expect(BookingDraft(action: .inventory, productID: 7, product: product).amount == 4)
    }

    @Test("A purchase leaves the due date to the product's own shelf life")
    func purchaseOmitsDueDate() {
        let draft = BookingDraft(action: .purchase, productID: 7, product: product)

        guard case .purchase(_, _, let due, let price, _, _, _, _) = draft.request else {
            Issue.record("expected a purchase")
            return
        }
        // Not the oldest lot's date, and not today: omitted, so the server
        // applies the product's default, freezer rule included.
        #expect(due == nil)
        #expect(price == nil)
    }

    @Test("A price is sent only when one was entered")
    func priceIsOptIn() {
        var draft = BookingDraft(action: .purchase, productID: 7, product: product)
        draft.price = 2.5
        guard case .purchase(_, _, _, let unset, _, _, _, _) = draft.request else { return }
        #expect(unset == nil)

        draft.usesPrice = true
        guard case .purchase(_, _, _, let set, _, _, _, _) = draft.request else { return }
        #expect(set == 2.5)
    }

    @Test("Naming a lot books exactly one")
    func namedLotIsOne() {
        var draft = BookingDraft(action: .consume, productID: 7, product: product)
        draft.amount = 3
        draft.stockEntryID = "lot-1"

        #expect(draft.amount == 1)
        #expect(draft.isValid)

        draft.amount = 2
        #expect(!draft.isValid)
    }

    @Test("A per-unit label's draft names the lot")
    func draftFromEntry() {
        let entry = StockEntry(id: 77, stockID: "lot-77", productID: 7, locationID: 5, amount: 1)
        let draft = BookingDraft(action: .consume, entry: entry, product: product)

        #expect(draft.productID == 7)
        #expect(draft.amount == 1)
        #expect(
            draft.request
                == .consume(productID: 7, amount: 1, stockEntryID: "lot-77"))
    }

    @Test("A transfer needs two different locations")
    func transferNeedsTwoLocations() {
        var draft = BookingDraft(action: .transfer, productID: 7, product: product)
        #expect(draft.locationID == 2)
        #expect(!draft.isValid)

        draft.destinationID = 2
        #expect(!draft.isValid)

        draft.destinationID = 3
        #expect(draft.isValid)
        #expect(
            draft.request
                == .transfer(productID: 7, amount: 1, fromLocationID: 2, toLocationID: 3))
    }

    @Test("An inventory of zero is a count; other bookings of zero are not")
    func zeroAmounts() {
        var inventory = BookingDraft(action: .inventory, productID: 7, product: product)
        inventory.amount = 0
        #expect(inventory.isValid)

        var consume = BookingDraft(action: .consume, productID: 7, product: product)
        consume.amount = 0
        #expect(!consume.isValid)
    }

    @Test("A blank note is not sent")
    func blankNote() {
        var draft = BookingDraft(action: .purchase, productID: 7, product: product)
        draft.note = "   "
        guard case .purchase(_, _, _, _, _, _, _, let note) = draft.request else { return }
        #expect(note == nil)
    }
}
