import Darwin
import Foundation
import FocusGuardCore

/// Enumerates processes with libproc (works as root with no window server) and maps each
/// executable path to the bundle ID of the innermost `.app` containing it, so a helper like
/// `Slack.app/Contents/Frameworks/Slack Helper.app/...` reports the helper's own ID.
final class LibprocProcessController: ProcessController {
    /// Bundle path → the Info.plist it was read from and the ID found. Re-read when the plist's
    /// inode or modification time changes, so putting a different app at a path already seen (to
    /// borrow its cached "not blocked" answer) does not work. Costs one `stat` per app process.
    private var bundleIDCache: [String: (plist: PlistIdentity?, id: String?)] = [:]

    private struct PlistIdentity: Equatable {
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanos: Int

        init?(bundlePath: String) {
            var st = stat()
            guard stat(bundlePath + "/Contents/Info.plist", &st) == 0 else { return nil }
            inode = UInt64(st.st_ino)
            modifiedSeconds = Int(st.st_mtimespec.tv_sec)
            modifiedNanos = Int(st.st_mtimespec.tv_nsec)
        }
    }

    func runningApps() -> [RunningApp] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).compactMap { pid in
            guard pid > 0, let path = executablePath(pid) else { return nil }
            return RunningApp(pid: pid, bundleID: bundleID(forExecutablePath: path))
        }
    }

    func terminate(pid: Int32) { _ = Darwin.kill(pid, SIGTERM) }
    func kill(pid: Int32) { _ = Darwin.kill(pid, SIGKILL) }

    private func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is `4 * MAXPATHLEN`, a computed macro Swift cannot import.
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private func bundleID(forExecutablePath path: String) -> String? {
        guard let r = path.range(of: ".app/", options: .backwards) else { return nil }
        let bundlePath = String(path[..<r.lowerBound]) + ".app"
        let plist = PlistIdentity(bundlePath: bundlePath)
        if let cached = bundleIDCache[bundlePath], cached.plist == plist { return cached.id }
        // Read the plist directly: `Bundle(path:)` keeps its own per-process cache of the bundle.
        let id = (NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String)
        bundleIDCache[bundlePath] = (plist, id)
        return id
    }
}
