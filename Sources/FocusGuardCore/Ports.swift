import Foundation

public protocol HostsFileStore {
    func read() throws -> String
    func write(_ contents: String) throws
}

public protocol DNSCacheFlusher {
    func flush()
}

public struct RunningApp: Equatable {
    public let pid: Int32
    public let bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

public protocol ProcessController {
    func runningApps() -> [RunningApp]
    /// Polite request (SIGTERM).
    func terminate(pid: Int32)
    /// Forceful (SIGKILL).
    func kill(pid: Int32)
}

public protocol ReconcilerLog {
    func info(_ message: String)
    func error(_ message: String)
}

/// Chrome's `URLBlocklist` policy preference (chrome pages spec §3). The daemon's implementation
/// writes CFPreferences and keeps an ownership record; tests use a recording fake. Every method
/// is cheap enough to call on a 2 s tick, but the Reconciler calls `apply`/`clear` only when the
/// wanted set changes.
public protocol ChromePolicyWriter {
    /// The patterns FocusGuard itself last wrote, from its ownership record on disk; nil when it
    /// has never written the key, or has since cleared it. Read once, at the first tick, so a
    /// restarted daemon can tell its own key from a user's.
    func recordedPatterns() -> [String]?
    /// Whether `URLBlocklist` is set at all right now, by anyone.
    func keyIsPresent() -> Bool
    /// Make the key equal `patterns` (never empty) and update the record. nil on success,
    /// otherwise a short reason for the status line.
    func apply(patterns: [String]) -> String?
    /// Remove the key and the record. nil on success.
    func clear() -> String?
    /// For the status line only: nothing is skipped when Chrome is absent.
    var chromeInstalled: Bool { get }
}
