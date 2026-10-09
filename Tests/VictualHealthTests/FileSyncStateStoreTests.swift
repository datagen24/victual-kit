import Foundation
import Testing
@testable import VictualHealth

@Suite("File sync state store")
struct FileSyncStateStoreTests {
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("victual-health-\(UUID().uuidString)")
    }

    @Test func emptyDirectoryReadsAsEmpty() async throws {
        let store = FileSyncStateStore(directory: directory())
        let queue = try await store.loadQueue(for: .init(server: "s", account: "a"))
        #expect(queue == SyncQueue())
        #expect(try await store.loadAnchor(for: .init(accountKey: .init(server: "s", account: "a"), mappingSet: "m")) == nil)
    }

    @Test func roundTripsQueueAndAnchorAcrossInstances() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = AccountKey(server: "https://v.example", account: "me")
        let anchorKey = AnchorKey(accountKey: account, mappingSet: "m1")
        var queue = SyncQueue()
        queue.outbox = [OutboxRecord(
            sequence: 1, eventID: "D1",
            operation: .put(.init(status: .taken, medicationRef: "m", quantity: 1, unitLabel: "tablet",
                                  occurredAt: RFC3339Timestamp(Fixtures.t0, in: Fixtures.zone))))]
        queue.nextSequence = 2

        let writer = FileSyncStateStore(directory: dir)
        try await writer.saveQueue(queue, for: account)
        try await writer.saveAnchor(Data("anchor".utf8), for: anchorKey)

        let reader = FileSyncStateStore(directory: dir)  // a relaunch
        #expect(try await reader.loadQueue(for: account) == queue)
        #expect(try await reader.loadAnchor(for: anchorKey) == Data("anchor".utf8))
    }

    @Test func accountsAndMappingSetsGetSeparateFiles() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSyncStateStore(directory: dir)
        let me = AccountKey(server: "s", account: "me"), other = AccountKey(server: "s", account: "other")
        try await store.saveAnchor(Data("1".utf8), for: .init(accountKey: me, mappingSet: "m"))
        #expect(try await store.loadAnchor(for: .init(accountKey: other, mappingSet: "m")) == nil)
        #expect(try await store.loadAnchor(for: .init(accountKey: me, mappingSet: "m2")) == nil)
    }

    @Test func writesAskForFileProtectionWhereThePlatformHasIt() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            #expect(FileSyncStateStore.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
            #expect(FileSyncStateStore.requestsFileProtection)
        #else
            // macOS has no file-protection option; the production target is iOS.
            #expect(!FileSyncStateStore.requestsFileProtection)
        #endif
        #expect(FileSyncStateStore.writeOptions.contains(.atomic))
    }
}
