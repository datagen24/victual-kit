import Foundation
import Observation
import SwiftUI
import VictualCore
import VictualStock

/// The five stores one connected window works with, and the wiring between them.
///
/// The stores themselves live in `VictualStock` and know nothing about each
/// other; what they need on top is a window's worth of coordination — a booking
/// should refresh the list and the inspector, and a change made elsewhere should
/// refresh everything. That is what this is, and it is why it lives in the
/// application rather than the package: it is about a window's lifecycle.
@MainActor
@Observable
final class StockWorkspace {
    let stock: StockStore
    let detail: ProductDetailStore
    let bookings: BookingController
    let capabilities: CapabilityGate
    let poller: ChangePoller

    /// Which booking sheet is open, if any.
    var presentedBooking: StockAction?

    /// The product a booking sheet is about.
    var bookingTarget: Int?

    init(client: VictualClient) {
        self.stock = StockStore(client: client)
        self.detail = ProductDetailStore(client: client)
        self.bookings = BookingController(client: client)
        self.capabilities = CapabilityGate(client: client)
        self.poller = ChangePoller(client: client)
    }

    /// The first load, plus the polling loop.
    func start() async {
        async let capabilitiesLoad: Void = capabilities.load()
        async let stockLoad: Void = stock.refresh()
        _ = await (capabilitiesLoad, stockLoad)

        poller.start { [weak self] in
            // Something changed on the server — another device, the web UI, a
            // chore. Re-read rather than guessing what moved.
            await self?.refreshAll()
        }
    }

    func stop() {
        poller.stop()
    }

    /// Re-reads the list and, if one is open, the inspector.
    func refreshAll() async {
        await stock.refresh()
        detail.refresh()
        await detail.waitForLoad()
    }

    /// Performs a booking and brings the screen back in line with the server.
    ///
    /// The refresh happens whether or not the booking succeeded: a `403` or a
    /// `400` can still mean the server's state is not what the screen last
    /// showed, and re-reading is cheaper than reasoning about it.
    func perform(_ request: BookingRequest) async {
        await bookings.perform(request)
        await refreshAll()
    }

    /// Undoes the last booking and re-reads.
    func undoLastBooking() async {
        await bookings.undoLast()
        await refreshAll()
    }

    /// Opens a booking sheet for `action` against the selected product.
    ///
    /// Does nothing when nothing is selected: every booking addresses a product,
    /// and there is no sensible default.
    func beginBooking(_ action: StockAction) {
        guard let productID = detail.productID ?? stock.rows.first?.productID else { return }
        bookingTarget = productID
        presentedBooking = action
    }

    /// Whether `action` can be started right now: the permission allows it and
    /// there is a product to address it to.
    func canBegin(_ action: StockAction) -> Bool {
        capabilities.canWrite(action) && detail.productID != nil
    }

    /// Why `action` is unavailable, for a tooltip. Permission first: that is the
    /// answer a household member actually needs.
    func reason(_ action: StockAction) -> String? {
        capabilities.reason(action) ?? (detail.productID == nil ? "Select a product first." : nil)
    }
}
