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
