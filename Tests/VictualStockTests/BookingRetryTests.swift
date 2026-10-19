import Foundation
import Testing
import VictualCore
import VictualTestSupport

@testable import VictualStock

private let allOperations = ["purchase", "consume", "transfer", "open", "inventory"]

/// One key per intended booking, reused when that booking is sent again.
///
/// These are ADR-0046's client obligations as the controller carries them out:
/// a booking whose outcome is unknown may be retried only under its first key,
/// only against a server that honours keys, and only inside its retention.
@Suite("BookingController retries")
@MainActor
struct BookingRetryTests {
    private func controller(
        operations: [String]? = allOperations,
        answers: [BookingAnswer]
    ) -> (BookingController, StubTransport) {
        let transport = StubTransport.bookingServer(
            systemInfo: systemInfoJSON(idempotentOperations: operations),
            answers: answers
        )
        return (BookingController(client: VictualClient.stubbed(transport)), transport)
    }

    private func keys(_ transport: StubTransport) -> [String?] {
        transport.recorder.bookings.map { $0.request.headerFields[idempotencyKeyField] }
    }

    @Test("A retry after an unknown outcome reuses the first key, and books once")
    func retryReusesKey() async throws {
        let (controller, transport) = controller(answers: [.timedOut, .booked(replayed: true)])

        let first = await controller.perform(.consume(productID: 7, amount: 1))
        #expect(!first)
        #expect(controller.error?.isOutcomeUnknown == true)
        #expect(controller.canRetryLast)

        let retried = await controller.retryLast()

        #expect(retried)
        let sent = keys(transport)
        #expect(sent.count == 2)
        #expect(sent[0] != nil)
        #expect(sent[0] == sent[1])
        #expect(controller.lastBooking?.isReplayed == true)
        #expect(!controller.canRetryLast)
    }

    @Test("Performing the same booking again reuses the key; a different one gets a new key")
    func sameRequestSameKey() async throws {
        let (controller, transport) = controller(
            answers: [.timedOut, .timedOut, .booked(replayed: false)]
        )
        let request = BookingRequest.purchase(productID: 7, amount: 2)

        await controller.perform(request)
        await controller.perform(request)
        await controller.perform(.purchase(productID: 7, amount: 3))

        let sent = keys(transport)
        #expect(sent.count == 3)
        #expect(sent[0] == sent[1])
        #expect(sent[1] != sent[2])
    }

    @Test("After a success the next booking, even an identical one, gets a new key")
    func successRetiresKey() async throws {
        let (controller, transport) = controller(answers: [.booked(replayed: false)])
        let request = BookingRequest.consume(productID: 7, amount: 1)

        await controller.perform(request)
        await controller.perform(request)

        let sent = keys(transport)
        #expect(sent.count == 2)
        #expect(sent[0] != sent[1])
    }

    @Test("Against a server that ignores keys, an unknown outcome is not offered for retry")
    func olderServerCannotRetry() async throws {
        let (controller, transport) = controller(
            operations: nil,
            answers: [.timedOut, .booked(replayed: nil)]
        )

        await controller.perform(.consume(productID: 7, amount: 1))

        #expect(controller.error?.isOutcomeUnknown == true)
        #expect(!controller.canRetryLast)
        #expect(await controller.retryLast() == false)
        #expect(transport.recorder.bookings.count == 1)
        #expect(keys(transport) == [nil])
    }

    @Test("An operation the server does not protect is not offered for retry")
    func unprotectedOperationCannotRetry() async throws {
        let (controller, _) = controller(operations: ["consume"], answers: [.timedOut])

        await controller.perform(.transfer(productID: 7, amount: 1, fromLocationID: 1, toLocationID: 2))

        #expect(controller.error?.isOutcomeUnknown == true)
        #expect(!controller.canRetryLast)
    }

    @Test("idempotency_in_progress is retried later under the same key")
    func inProgressRetriesSameKey() async throws {
        let (controller, transport) = controller(
            answers: [.conflict(code: "idempotency_in_progress"), .booked(replayed: true)]
        )

        await controller.perform(.open(productID: 7, amount: 1))
        #expect(controller.error == .idempotencyInProgress(message: "refused: idempotency_in_progress"))
        #expect(controller.canRetryLast)

        #expect(await controller.retryLast())
        let sent = keys(transport)
        #expect(sent.count == 2)
        #expect(sent[0] == sent[1])
    }

    @Test("idempotency_conflict stops: no retry, and the key is not used again")
    func conflictStops() async throws {
        let (controller, transport) = controller(
            answers: [.conflict(code: "idempotency_conflict"), .booked(replayed: false)]
        )
        let request = BookingRequest.inventory(productID: 7, newAmount: 4)

        await controller.perform(request)
        #expect(controller.error == .idempotencyConflict(message: "refused: idempotency_conflict"))
        #expect(controller.error?.isRetryable == false)
        #expect(!controller.canRetryLast)
        #expect(await controller.retryLast() == false)

        await controller.perform(request)
        let sent = keys(transport)
        #expect(sent.count == 2)
        #expect(sent[0] != sent[1])
    }

    @Test("Once retention has passed since the first attempt, the key is not retried")
    func retentionEndsRetry() async throws {
        let (controller, transport) = controller(answers: [.timedOut, .booked(replayed: false)])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        controller.now = { start }

        await controller.perform(.consume(productID: 7, amount: 1))
        #expect(controller.canRetryLast)

        // Retention counts from the first send, so a wait of exactly the
        // published window is already too long.
        controller.now = { start.addingTimeInterval(604_800) }
        #expect(await controller.retryLast() == false)
        #expect(!controller.canRetryLast)
        #expect(transport.recorder.bookings.count == 1)

        // Performing it again by hand is a new booking, under a new key.
        await controller.perform(.consume(productID: 7, amount: 1))
        let sent = keys(transport)
        #expect(sent.count == 2)
        #expect(sent[0] != sent[1])
    }
}
