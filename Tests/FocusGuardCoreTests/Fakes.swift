import Foundation
@testable import FocusGuardCore

final class FakeHosts: HostsFileStore {
    var contents: String
    var writes = 0
    var failReads = false
    init(_ contents: String) { self.contents = contents }
    struct Failure: Error {}
    func read() throws -> String {
        if failReads { throw Failure() }
        return contents
    }
    func write(_ new: String) throws { contents = new; writes += 1 }
}

final class FakeDNS: DNSCacheFlusher {
    var flushes = 0
    func flush() { flushes += 1 }
}

final class FakeProcesses: ProcessController {
    var apps: [RunningApp] = []
    var terminated: [Int32] = []
    var killed: [Int32] = []
    var enumerations = 0
    func runningApps() -> [RunningApp] { enumerations += 1; return apps }
    func terminate(pid: Int32) { terminated.append(pid) }
    func kill(pid: Int32) { killed.append(pid); apps.removeAll { $0.pid == pid } }
}

final class FakeLog: ReconcilerLog {
    var infos: [String] = []
    var errors: [String] = []
    func info(_ m: String) { infos.append(m) }
    func error(_ m: String) { errors.append(m) }
}

/// A process that ignores SIGKILL (protected or zombie): stays in the list after kill.
final class StubbornProcesses: ProcessController {
    var apps: [RunningApp] = []
    var terminated: [Int32] = []
    var killed: [Int32] = []
    func runningApps() -> [RunningApp] { apps }
    func terminate(pid: Int32) { terminated.append(pid) }
    func kill(pid: Int32) { killed.append(pid) }
}
