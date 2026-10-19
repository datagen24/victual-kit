import SwiftUI
import VictualCore

extension View {
    /// The alert a failed booking raises, with "Try again" when the booking can
    /// be resent under its original key.
    ///
    /// - Parameter isSuppressed: True while something else reports the error,
    ///   as the booking form does while it is up.
    func bookingErrorAlert(workspace: PhoneWorkspace, isSuppressed: Bool = false) -> some View {
        modifier(BookingErrorAlert(workspace: workspace, isSuppressed: isSuppressed))
    }
}

private struct BookingErrorAlert: ViewModifier {
    let workspace: PhoneWorkspace
    let isSuppressed: Bool

    /// Set from the moment "Try again" is tapped until the retry has answered.
    ///
    /// The alert's own dismissal must not clear the error: that also withdraws
    /// the retry the button is about to ask for. So the buttons clear it, and
    /// this keeps the alert from coming back between the tap and the retry
    /// starting.
    @State private var isRetrying = false

    func body(content: Content) -> some View {
        let bookings = workspace.bookings
        content.alert(
            "That did not work",
            isPresented: Binding(
                get: { bookings.error != nil && !isSuppressed && !isRetrying },
                // Only the buttons dismiss an alert on iOS, and each says what
                // it does with the error.
                set: { _ in }
            )
        ) {
            if bookings.canRetryLast {
                Button("Try again") {
                    isRetrying = true
                    Task {
                        await workspace.retryLastBooking()
                        isRetrying = false
                    }
                }
                Button("Cancel", role: .cancel) { bookings.clearError() }
            } else {
                Button("OK", role: .cancel) { bookings.clearError() }
            }
        } message: {
            Text(Self.message(for: bookings.error, canRetry: bookings.canRetryLast))
        }
    }

    /// What to say about `error`, given whether it can be sent again.
    ///
    /// Without a retry — every server before 0.5.0 — an unknown outcome reads as
    /// it always has: check the stock, because sending it again could book twice.
    static func message(for error: VictualError?, canRetry: Bool) -> String {
        guard let error else { return "" }
        switch error {
        case .outcomeUnknown where canRetry:
            return "The server did not answer in time, so it is not known whether that was recorded. "
                + "Try again sends the same booking; the server will not record it twice."
        case .idempotencyInProgress where canRetry:
            return "The server is still recording this booking. Try again in a moment: "
                + "it sends the same booking, and the server will not record it twice."
        case .idempotencyInProgress:
            return "The server is still recording this booking, and it can no longer be sent again safely. "
                + "Stock has been refreshed. Check it before booking again."
        case .idempotencyConflict:
            return (error.errorDescription ?? "")
                + " Stock has been refreshed. Check it before booking again."
        default:
            return error.errorDescription ?? ""
        }
    }
}
