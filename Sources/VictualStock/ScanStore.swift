import Foundation
import Observation
import VictualCore

/// The scanner's state: which code was last read, and what the server said it
/// is.
///
/// ## Why a camera needs debouncing
///
/// A live scanner reports the same barcode for as long as it stays in frame,
/// and reports it again the moment it re-enters. Left alone that means a
/// lookup per frame while the result is on screen, and — worse — the result
/// popping straight back up when the person dismisses it with the package still
/// in their hand. So a code that is the same as the last one read, within
/// ``repeatWindow`` of when it was last seen, is ignored. Moving the package
/// away for longer than that makes it scannable again.
///
/// A code typed in or read from a photo is a deliberate act, not a frame, and
/// is submitted with `force: true`, which skips the window.
@MainActor
@Observable
public final class ScanStore {
    public enum Phase: Sendable, Equatable {
        /// Nothing scanned, or the last result was dismissed.
        case idle
        case resolving
        case resolved(ScanResolution)
        case failed(VictualError)

        public var isResolving: Bool { self == .resolving }

        public var resolution: ScanResolution? {
            if case .resolved(let resolution) = self { return resolution }
            return nil
        }

        public var error: VictualError? {
            if case .failed(let error) = self { return error }
            return nil
        }
    }

    /// The code the current ``phase`` is about.
    public private(set) var code: String?
    public private(set) var phase: Phase = .idle

    /// How long the same code is ignored after it was last seen.
    public var repeatWindow: TimeInterval = 3

    private let client: VictualClient
    private let now: @Sendable () -> Date
    private var lastSeen: (code: String, at: Date)?
    private var task: Task<Void, Never>?

    /// - Parameter now: The clock the repeat window is measured against.
    ///   Injected so a test can move time rather than wait for it.
    public init(client: VictualClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// Looks up a scanned or typed code.
    ///
    /// - Parameters:
    ///   - rawCode: The payload as read. Surrounding whitespace is dropped —
    ///     a hand-held scanner commonly appends a newline — and nothing else is
    ///     touched: what a code *means* is the server's business.
    ///   - force: Skip the repeat window. Use it for anything a person did on
    ///     purpose.
    /// - Returns: Whether a lookup was started.
    @discardableResult
    public func submit(_ rawCode: String, force: Bool = false) -> Bool {
        let scanned = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scanned.isEmpty else { return false }

        let moment = now()
        defer { lastSeen = (scanned, moment) }
        if !force, let lastSeen, lastSeen.code == scanned,
            moment.timeIntervalSince(lastSeen.at) < repeatWindow
        {
            return false
        }

        resolve(scanned)
        return true
    }

    /// Looks the current code up again — after a booking, so the amount shown
    /// is the amount there now.
    public func refresh() {
        guard let code else { return }
        resolve(code)
    }

    /// Dismisses the result.
    ///
    /// The code stays in the repeat window: the package is usually still in
    /// front of the camera when the result is put away.
    public func clear() {
        task?.cancel()
        task = nil
        code = nil
        phase = .idle
        if let lastSeen { self.lastSeen = (lastSeen.code, now()) }
    }

    /// Awaits the lookup in flight, if there is one.
    public func waitForResolution() async {
        await task?.value
    }

    private func resolve(_ scanned: String) {
        task?.cancel()
        code = scanned
        phase = .resolving
        task = Task { [weak self, client] in
            do {
                let resolution = try await client.resolveScan(scanned)
                guard !Task.isCancelled, let self, self.code == scanned else { return }
                self.phase = .resolved(resolution)
            } catch {
                guard !Task.isCancelled, let self, self.code == scanned else { return }
                self.phase = .failed(VictualError.mapping(error))
            }
        }
    }
}
