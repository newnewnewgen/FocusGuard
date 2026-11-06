import Darwin
import Foundation

/// Is a `focusguardd` running, and from where? One libproc pass, only when asked (Status tab
/// shown, after an install action). Never on a timer or a boundary.
enum DaemonProbe {
    struct Result: Equatable {
        let pid: pid_t
        let path: String
        /// When the process started; nil if the kernel would not say.
        let started: Date?
        var isFromBundle: Bool { path.contains("/FocusGuard.app/Contents/MacOS/focusguardd") }

        /// The executable on disk is newer than the running process: the bundle was updated and
        /// this daemon is still the old code. One second of slack for timestamp granularity.
        var isOlderThanBinary: Bool {
            guard let started,
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { return false }
            return started.addingTimeInterval(1) < modified
        }
    }

    /// `ps` gets start times for other users' processes the same way; no privilege needed.
    private static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
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
            if path.hasSuffix("/focusguardd") { return Result(pid: pid, path: path, started: startTime(of: pid)) }
        }
        return nil
    }
}
