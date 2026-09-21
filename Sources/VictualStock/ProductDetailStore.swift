import Foundation
import Observation
import VictualCore

/// One product and the lots it is made of, for the inspector column.
///
/// Two requests, because the detail and the entries are two endpoints. They go
/// out together, and a failure of either leaves the previous product on screen
/// rather than blanking the inspector.
@MainActor
@Observable
public final class ProductDetailStore {
    public private(set) var detail: ProductDetail?
    public private(set) var entries: [StockEntry] = []
    public private(set) var state: LoadState = .idle

    /// The product currently loaded, or being loaded.
    public private(set) var productID: Int?

    /// Whether to include a parent product's children's lots.
    public var includeSubProducts: Bool = false

    private let client: VictualClient
    private var task: Task<Void, Never>?

    public init(client: VictualClient) {
        self.client = client
    }

    /// Loads a product, or clears the inspector when given `nil`.
    ///
    /// Supersedes an in-flight load, so clicking quickly down a table cannot
    /// leave the inspector showing an earlier row's product.
    public func select(_ productID: Int?) {
        guard productID != self.productID else { return }
        task?.cancel()
        self.productID = productID
        guard let productID else {
            detail = nil
            entries = []
            state = .idle
            return
        }
        load(productID)
    }

    /// Re-reads the currently selected product.
    public func refresh() {
        guard let productID else { return }
        task?.cancel()
        load(productID)
    }

    /// Awaits the in-flight load, if there is one.
    public func waitForLoad() async {
        await task?.value
    }

    /// The lots, ordered the way a person reads them: soonest due first, then
    /// the ones with no due date.
    public var orderedEntries: [StockEntry] {
        entries.sorted { first, second in
            switch (first.bestBeforeDate, second.bestBeforeDate) {
            case (nil, nil): return first.id < second.id
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?): return a == b ? first.id < second.id : a < b
            }
        }
    }

    private func load(_ productID: Int) {
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                async let detailTask = client.productDetail(id: productID)
                async let entriesTask = client.stockEntries(
                    productID: productID,
                    includeSubProducts: includeSubProducts
                )
                let loaded = try await detailTask
                let lots = try await entriesTask
                guard !Task.isCancelled, self.productID == productID else { return }
                self.detail = loaded
                self.entries = lots
                self.state = .loaded
            } catch {
                guard !Task.isCancelled, self.productID == productID else { return }
                self.state = .failed(VictualError.mapping(error))
            }
        }
    }
}
