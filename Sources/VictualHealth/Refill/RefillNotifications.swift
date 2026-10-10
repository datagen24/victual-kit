import CryptoKit
import Foundation

/// The device's local notification centre, behind a protocol so the rules can be
/// tested without one. The phone's implementation wraps `UNUserNotificationCenter`.
public protocol RefillNotificationCenter: Sendable {
    /// Whether the person has allowed notifications. Never prompts.
    func isAuthorized() async -> Bool
    /// Shows the system permission prompt. Called only from an explicit tap.
    func requestAuthorization() async -> Bool
    /// Posts a notification now, with `identifier` as its identity so a repeat
    /// replaces rather than duplicates.
    func post(identifier: String, title: String, body: String) async throws
    /// Removes pending and delivered notifications with these identifiers.
    func remove(identifiers: [String]) async
    /// Removes every refill notification, pending and delivered.
    func removeAll() async
}

/// What a notification says. Fixed text: it names no medication, no prescription
/// and no date, and advises nothing (ADR-0015, ADR-0042 §6), because it appears on
/// a lock screen. Detail is a tap away, behind the app.
public enum RefillNotificationContent {
    public static let title = "Victual"

    public static func body(for kind: RefillNotice.Kind) -> String {
        switch kind {
        case .approaching: "A refill is coming up."
        case .due: "A refill reorder date has arrived."
        }
    }
}

/// What this device remembers about refills between launches.
///
/// No name and no medication detail: notice keys (a recipe number, a kind and a date),
/// delivery times, and the last reorder date seen for each recipe.
public struct RefillLocalState: Sendable, Equatable, Codable {
    public struct Correction: Sendable, Equatable, Codable {
        public var from: CalendarDay
        public var to: CalendarDay
    }

    /// Keys already posted as notifications, and when. Survives a relaunch so a
    /// retry or a restart does not post the same notice again.
    public var delivered: [String: Date] = [:]
    /// Acknowledgements the person made that the server has not confirmed yet.
    public var pendingAcknowledgements: [String] = []
    public var lastReorderDate: [Int: CalendarDay] = [:]
    public var corrections: [Int: Correction] = [:]

    public init() {}

    /// A delivered key is forgotten after this long, so the ledger cannot grow
    /// without bound. Long enough that a notice an open order suppressed and a
    /// cancelled order restored is still recognised.
    static let retention: TimeInterval = 90 * 24 * 60 * 60
}

public protocol RefillStateStore: Sendable {
    func load(server: String, account: String) async throws -> RefillLocalState
    func save(_ state: RefillLocalState, server: String, account: String) async throws
    func erase(server: String, account: String) async throws
}

public actor FileRefillStateStore: RefillStateStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(server: String, account: String) throws -> RefillLocalState {
        do {
            return try JSONDecoder().decode(RefillLocalState.self, from: Data(contentsOf: file(server, account)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return RefillLocalState()
        }
    }

    public func save(_ state: RefillLocalState, server: String, account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file(server, account), options: FileSyncStateStore.writeOptions)
    }

    public func erase(server: String, account: String) throws {
        try? FileManager.default.removeItem(at: file(server, account))
    }

    private func file(_ server: String, _ account: String) -> URL {
        let text = [server, account].joined(separator: "\u{1F}")
        let stem = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("refill-\(stem).json")
    }
}

public actor InMemoryRefillStateStore: RefillStateStore {
    private var stored: RefillLocalState?

    public init() {}

    public func load(server: String, account: String) -> RefillLocalState { stored ?? RefillLocalState() }
    public func save(_ state: RefillLocalState, server: String, account: String) { stored = state }
    public func erase(server: String, account: String) { stored = nil }
    public var isEmpty: Bool { stored == nil }
}
