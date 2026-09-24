import Foundation
import Observation
import VictualCore
import VictualStock

/// A booking form on its way to the screen.
///
/// The draft is the form's state; the product rides along so the form can name
/// it and render its unit without another request.
struct BookingPresentation: Identifiable {
    let id = UUID()
    var draft: BookingDraft
    let product: ProductDetail?
}

/// The stores one connected phone works with, and the wiring between them.
///
/// The macOS application has the same object for a window (`StockWorkspace`).
/// This one differs in what it adds rather than in what it is: the scanner, and
/// one-tap bookings that skip the form.
@MainActor
@Observable
final class PhoneWorkspace {
    let client: VictualClient
    let stock: StockStore
    let bookings: BookingController
    let capabilities: CapabilityGate
    let poller: ChangePoller
    let scanner: ScanStore

    /// The booking form currently shown, if any.
    var presentedBooking: BookingPresentation?

    init(client: VictualClient) {
        self.client = client
        self.stock = StockStore(client: client)
        self.bookings = BookingController(client: client)
        self.capabilities = CapabilityGate(client: client)
        self.poller = ChangePoller(client: client)
        self.scanner = ScanStore(client: client)
    }

    /// The first load, and the polling loop while the app is in front.
    func start() async {
        async let capabilitiesLoad: Void = capabilities.load()
        async let stockLoad: Void = stock.refresh()
        _ = await (capabilitiesLoad, stockLoad)
        resume()
    }

    /// Starts polling again, after the app returns to the foreground.
    func resume() {
        poller.start { [weak self] in
            await self?.stock.refresh()
        }
    }

    /// Stops polling. A phone in a pocket has no reason to ask the server
    /// anything.
    func stop() {
        poller.stop()
    }

    /// Performs a booking, then brings the list and the scan result back in
    /// line with the server — whether or not it succeeded, for the reason the
    /// macOS workspace gives: a refusal can still mean the screen is stale.
    @discardableResult
    func perform(_ request: BookingRequest) async -> Bool {
        let succeeded = await bookings.perform(request)
        scanner.refresh()
        await stock.refresh()
        return succeeded
    }

    func undoLastBooking() async {
        await bookings.undoLast()
        scanner.refresh()
        await stock.refresh()
    }

    /// Books one of `product` without a form: the scanner's reason to exist.
    ///
    /// Only for consume and open, where "one" is almost always what is meant.
    /// Everything else opens the form. The undo bar is the safety net: a wrong
    /// tap costs one more tap, which is cheaper than a confirmation on every
    /// right one.
    func bookOne(_ action: StockAction, of product: ProductDetail, entry: StockEntry? = nil) async {
        let draft =
            if let entry {
                BookingDraft(action: action, entry: entry, product: product)
            } else {
                BookingDraft(action: action, productID: product.id, product: product)
            }
        await perform(draft.request)
    }

    /// Opens the booking form for `action`.
    func beginBooking(
        _ action: StockAction,
        product: ProductDetail,
        entry: StockEntry? = nil
    ) {
        let draft =
            if let entry {
                BookingDraft(action: action, entry: entry, product: product)
            } else {
                BookingDraft(action: action, productID: product.id, product: product)
            }
        presentedBooking = BookingPresentation(draft: draft, product: product)
    }
}
