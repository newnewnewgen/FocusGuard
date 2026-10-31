import Darwin
import Foundation

/// Is a `focusguardd` running, and from where? One libproc pass, only when asked (Status tab
/// shown, after an install action, on a boundary). Never on a timer.
enum DaemonProbe {
    struct Result: Equatable {
        let pid: pid_t
        let path: String
        var isFromBundle: Bool { path.contains("/FocusGuard.app/Contents/MacOS/focusguardd") }
    }

    static func find() -> Result? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(got)) where pid > 0 {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            if path.hasSuffix("/focusguardd") { return Result(pid: pid, path: path) }
        }
        return nil
    }
}
