import Foundation
import Observation
import VictualCore

/// Watches `GET /system/db-changed-time` and reports only when it moves.
///
/// Re-fetching `/stock` on a timer would cost a full stock list every interval
/// whether or not anything changed. This costs one small request instead, and
/// the expensive refresh only happens when the household actually changed
/// something — from another device, from the web UI, or from a chore running
/// server-side.
///
/// ## Failing quietly rather than loudly
///
/// Polling is an optimisation, not a feature: if the timestamp cannot be read,
/// the application still works with manual refresh. So consecutive failures
/// stop the poller rather than producing an error every interval forever. The
/// last error stays on ``error`` for anyone who wants to show it.
@MainActor
@Observable
public final class ChangePoller {
    /// The timestamp last read from the server.
    public private(set) var lastChange: Date?

    /// Whether a polling loop is running.
    public private(set) var isPolling = false

    /// The last failure, kept after the poller gives up.
    public private(set) var error: VictualError?

    /// How many polls in a row have failed.
    public private(set) var consecutiveFailures = 0

    /// How long to wait between polls.
    ///
    /// Thirty seconds is a starting point, not a measured answer — plan 01's
    /// open question 3 — chosen so a change made elsewhere shows up within about
    /// the time it takes to walk back to the Mac.
    public var interval: Duration = .seconds(30)

    /// How many failures in a row end the loop.
    public var failureLimit = 3

    private let client: VictualClient
    private var task: Task<Void, Never>?

    public init(client: VictualClient) {
        self.client = client
    }

    /// Reads the timestamp once.
    ///
    /// - Returns: Whether it moved since the last read. The first successful
    ///   read returns `false`: it establishes the baseline rather than reporting
    ///   a change nobody made.
    @discardableResult
    public func checkNow() async -> Bool {
        do {
            let changed = try await client.databaseChangedTime()
            consecutiveFailures = 0
            error = nil
            defer { lastChange = changed }
            guard let previous = lastChange else { return false }
            return changed != previous
        } catch {
            consecutiveFailures += 1
            self.error = error
            return false
        }
    }

    /// Starts polling, calling `onChange` each time the timestamp moves.
    ///
    /// Supersedes any loop already running, so starting twice does not double
    /// the request rate.
    public func start(onChange: @escaping @MainActor @Sendable () async -> Void) {
        stop()
        isPolling = true
        consecutiveFailures = 0
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.checkNow() {
                    await onChange()
                }
                if self.consecutiveFailures >= self.failureLimit {
                    self.isPolling = false
                    return
                }
                let interval = self.interval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops polling. Safe to call when nothing is running.
    ///
    /// A poller that is simply released stops too, at its next wake-up: the loop
    /// holds `self` weakly and returns once it is gone. Calling this from a
    /// window's `onDisappear` makes that immediate rather than up to one
    /// interval late.
    public func stop() {
        task?.cancel()
        task = nil
        isPolling = false
    }
}
