import Foundation
import Observation
import VictualCore

/// Whether the server takes refill reads.
public enum RefillAvailability: Sendable, Equatable {
    case unknown
    case available
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        case olderServer
        case missingFeatures([String])
    }
}

/// Refill dates, state and notices for the Refills screen, and the local
/// notifications raised from the server's notices.
///
/// ## Rules (ADR-0042, plan 22)
/// - **"Today" is the client's.** Every read sends the local calendar date as
///   `as_of`; the server runs in UTC and does not know the person's day.
/// - **Notifications only for notices the server raised**, once per notice key: the
///   key (`<recipe>:<kind>:<reorder date>`) is the identity, kept on this device so
///   a retry or a relaunch does not repeat it, and a correction that changes the
///   date is a new key. None is scheduled for a future date, because an order placed
///   elsewhere in the meantime would make it false.
/// - **Acknowledgement is the person's** and is retried until the server confirms.
/// - **Revocation removes everything private.** If the server stops answering the
///   caller (401, 403), a prescription disappears from the list, or the person signs
///   out, the matching notifications are cancelled and the matching names and dates
///   are dropped from memory and from disk.
@MainActor
@Observable
public final class RefillStore {
    /// Features the refill reads need.
    nonisolated public static let requiredFeatures: Set<String> = ["refill", "refill_notices"]

    public private(set) var items: [RefillItem] = []
    public private(set) var notices: [RefillNotice] = []
    public private(set) var state: SyncState = .idle
    public private(set) var availability: RefillAvailability = .unknown
    public private(set) var lastRefreshed: Date?
    /// `true` once the server has refused the caller; everything private is gone.
    public private(set) var accessLost = false
    /// `nil` until asked.
    public private(set) var notificationsAllowed: Bool?

    private let source: any RefillSource
    private let notifications: any RefillNotificationCenter
    private let stateStore: any RefillStateStore
    private let server: String
    private let account: String
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private var isRefreshing = false

    public init(
        source: any RefillSource, notifications: any RefillNotificationCenter, stateStore: any RefillStateStore,
        server: String, account: String, now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.source = source
        self.notifications = notifications
        self.stateStore = stateStore
        self.server = server
        self.account = account
        self.now = now
        self.zone = zone
    }

    /// The local calendar date sent as `as_of`.
    public var today: CalendarDay { CalendarDay(now(), in: zone()) }

    /// Asks the server what it supports. A `404` is an older server, not a failure.
    public func checkAvailability() async {
        do {
            let features = Set(try await source.capabilities().features)
            let missing = Self.requiredFeatures.subtracting(features).sorted()
            availability = missing.isEmpty ? .available : .unavailable(.missingFeatures(missing))
        } catch {
            switch VictualError.mapping(error) {
            case .notFound: availability = .unavailable(.olderServer)
            case .unauthorized, .forbidden: await revoke()
                state = .failed(VictualError.mapping(error))
            case let failure: state = .failed(failure)
            }
        }
    }

    /// Reads refill state and notices for the local day, posts what is new, retries
    /// unconfirmed acknowledgements. Never throws: a failure lands in ``state``.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if availability == .unknown { await checkAvailability() }
        guard availability == .available else { return }

        state = .syncing
        let asOf = today
        do {
            var local = try await stateStore.load(server: server, account: account)
            let fetched = try await source.refills(asOf: asOf)
            let raised = try await source.notices(asOf: asOf)
            accessLost = false

            await removeVanished(fetched, from: &local)
            record(fetched, in: &local)
            await retryAcknowledgements(&local)

            items = fetched.map { item in
                var item = item
                if let correction = local.corrections[item.recipeID], correction.to == item.reorderDate {
                    item.correctedFrom = correction.from
                }
                return item
            }
            notices = raised.filter { !local.pendingAcknowledgements.contains($0.key) }
            await deliver(notices, &local)
            await removeStale(notices, &local)

            try? await stateStore.save(local, server: server, account: account)
            lastRefreshed = now()
            state = .synced
        } catch {
            await handle(VictualError.mapping(error))
        }
    }

    /// The person acknowledged a notice. Recorded first, so a crash or an offline
    /// phone still honours it; sent now; retried on later refreshes until confirmed.
    public func acknowledge(noticeKey key: String) async {
        var local = (try? await stateStore.load(server: server, account: account)) ?? RefillLocalState()
        if !local.pendingAcknowledgements.contains(key) { local.pendingAcknowledgements.append(key) }
        try? await stateStore.save(local, server: server, account: account)
        notices.removeAll { $0.key == key }
        await notifications.remove(identifiers: [key])
        await retryAcknowledgements(&local)
        try? await stateStore.save(local, server: server, account: account)
    }

    /// The fills behind one prescription, voided ones included, for the detail view.
    public func fills(recipeID: Int) async -> [RefillFillRecord] {
        do {
            return try await source.fills(recipeID: recipeID, asOf: today)
        } catch {
            switch VictualError.mapping(error) {
            // One prescription the caller cannot read is not a lost caller: the list
            // refresh already drops it, and nothing else is touched here.
            case .notFound: break
            case let failure: await handle(failure)
            }
            return []
        }
    }

    /// Shows the system prompt. Only from an explicit tap.
    public func requestNotificationPermission() async {
        notificationsAllowed = await notifications.requestAuthorization()
    }

    public func refreshNotificationPermission() async {
        notificationsAllowed = await notifications.isAuthorized()
    }

    /// Drops everything private: for a sign-out, a removed key, or a refused caller.
    public func revoke() async {
        await notifications.removeAll()
        try? await stateStore.erase(server: server, account: account)
        items = []
        notices = []
        lastRefreshed = nil
        accessLost = true
    }

    // MARK: Steps

    private func handle(_ failure: VictualError) async {
        switch failure {
        case .unauthorized, .forbidden:
            await revoke()
        case .notFound:
            availability = .unavailable(.olderServer)
            await revoke()
            accessLost = false
        default:
            break
        }
        state = .failed(failure)
    }

    /// A prescription that is no longer listed (share revoked, deleted) loses its
    /// notifications, ledger entries and remembered dates.
    private func removeVanished(_ fetched: [RefillItem], from local: inout RefillLocalState) async {
        let present = Set(fetched.map(\.recipeID))
        let gone = Set(local.lastReorderDate.keys).subtracting(present)
        guard !gone.isEmpty else { return }
        let stale = local.delivered.keys.filter { key in gone.contains(Self.recipeID(of: key) ?? -1) }
        await notifications.remove(identifiers: Array(stale))
        for key in stale { local.delivered[key] = nil }
        local.pendingAcknowledgements.removeAll { gone.contains(Self.recipeID(of: $0) ?? -1) }
        for id in gone {
            local.lastReorderDate[id] = nil
            local.corrections[id] = nil
        }
    }

    /// Remembers each recipe's reorder date, and notes a change as a correction.
    private func record(_ fetched: [RefillItem], in local: inout RefillLocalState) {
        for item in fetched {
            guard let date = item.reorderDate else { continue }
            if let previous = local.lastReorderDate[item.recipeID], previous != date {
                local.corrections[item.recipeID] = .init(from: previous, to: date)
            }
            local.lastReorderDate[item.recipeID] = date
        }
    }

    private func retryAcknowledgements(_ local: inout RefillLocalState) async {
        var remaining: [String] = []
        for key in local.pendingAcknowledgements {
            do {
                try await source.acknowledge(noticeKey: key)
            } catch {
                switch VictualError.mapping(error) {
                // The key no longer names anything the caller can read: nothing to confirm.
                case .badRequest, .notFound: break
                default: remaining.append(key)
                }
            }
        }
        local.pendingAcknowledgements = remaining
    }

    private func deliver(_ raised: [RefillNotice], _ local: inout RefillLocalState) async {
        notificationsAllowed = await notifications.isAuthorized()
        guard notificationsAllowed == true else { return }
        for notice in raised where local.delivered[notice.key] == nil {
            do {
                try await notifications.post(
                    identifier: notice.key, title: RefillNotificationContent.title,
                    body: RefillNotificationContent.body(for: notice.kind))
                local.delivered[notice.key] = now()
            } catch {
                continue  // not recorded, so the next refresh tries again
            }
        }
    }

    /// A delivered notification whose notice is no longer raised (acknowledged on
    /// another device, an order opened, the date corrected) is taken off the screen.
    /// Its key stays in the ledger for a while, so it is not re-posted if it returns.
    private func removeStale(_ raised: [RefillNotice], _ local: inout RefillLocalState) async {
        let live = Set(raised.map(\.key))
        let stale = local.delivered.keys.filter { !live.contains($0) }
        await notifications.remove(identifiers: stale)
        let cutoff = now().addingTimeInterval(-RefillLocalState.retention)
        local.delivered = local.delivered.filter { $0.value > cutoff }
    }

    static func recipeID(of key: String) -> Int? {
        key.split(separator: ":").first.flatMap { Int($0) }
    }
}
