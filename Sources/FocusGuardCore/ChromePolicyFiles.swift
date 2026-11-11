import Darwin
import Foundation

/// Ownership record for Chrome's `URLBlocklist` key (`Paths.chromePolicy`, chrome pages spec §3):
/// the patterns the daemon last wrote and whose user domain holds the mirror, so a restarted
/// daemon updates or removes exactly what it wrote. `uid`/`name` are nil in records written
/// before 0.6.0; the daemon then falls back to the console user. `staleMirrorUID` names a
/// previous user whose mirror could not be removed when the console user changed: `clear` and
/// the uninstall script try that user's domain too. Absent in records written before it existed.
public struct ChromePolicyRecord: Codable, Equatable {
    public var patterns: [String]
    public var writtenAt: Date
    public var uid: uid_t?
    public var name: String?
    public var staleMirrorUID: uid_t?

    public init(patterns: [String], writtenAt: Date, uid: uid_t?, name: String?, staleMirrorUID: uid_t? = nil) {
        self.patterns = patterns
        self.writtenAt = writtenAt
        self.uid = uid
        self.name = name
        self.staleMirrorUID = staleMirrorUID
    }

    public func encode() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data) -> ChromePolicyRecord? { try? JSONDecoder().decode(self, from: data) }
}

/// The file handed to `defaults import` for the user-domain mirror. `defaults write -array`
/// parses each element as a plist literal, so a pattern with `( ) { } [ ] < > "` or a comma is
/// rejected; `import` takes a real plist and merges its keys into the domain, leaving the
/// user's other Chrome keys alone.
public enum ChromeUserImport {
    public static let key = "URLBlocklist"

    public static func plistData(patterns: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [key: patterns], format: .xml, options: 0)
    }

    /// Whether a plist (any format) holds the key; nil when it is not a plist dictionary.
    public static func blocklistPresent(in data: Data) -> Bool? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return plist[key] != nil
    }
}

/// A root process reading a file the user controls. `FileManager.contents(atPath:)` would follow
/// a symlink anywhere and block forever on a FIFO; this opens without following, checks what it
/// got on the descriptor it holds, and reads at most the size it saw.
public enum BoundedUserFile {
    /// Identity of the file that was read, for a parse cache: taken from the open descriptor,
    /// so it describes the bytes returned and nothing a rename could swap in between.
    public struct Stamp: Equatable {
        public var dev: dev_t
        public var ino: ino_t
        public var mtimeSec: Int
        public var mtimeNsec: Int
        public var size: Int
    }

    public struct File {
        public var data: Data
        public var stamp: Stamp
    }

    public enum Outcome {
        /// No such file: a definite "not there".
        case absent
        /// Something is there but it is not a regular file of the user's within the limit —
        /// a symlink, a FIFO, a device, an oversized or foreign file. Nothing was read.
        case refused(String)
        case file(File)

        public var file: File? {
            if case .file(let f) = self { return f }
            return nil
        }
    }

    public static func read(path: String, uid: uid_t, limit: Int) -> Outcome {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return .absent }
            if err == ELOOP { return .refused("\(path) is a symlink") }
            return .refused("open \(path): \(String(cString: strerror(err)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .refused("fstat \(path): \(String(cString: strerror(errno)))") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .refused("\(path) is not a regular file") }
        guard st.st_uid == uid else { return .refused("\(path) is owned by uid \(st.st_uid), not \(uid)") }
        guard st.st_size >= 0, st.st_size <= limit else { return .refused("\(path) is \(st.st_size) bytes, over the \(limit)-byte limit") }
        let size = Int(st.st_size)
        var data = Data(count: size)
        var total = 0
        while total < size {
            let n = data.withUnsafeMutableBytes { buf -> Int in
                Darwin.read(fd, buf.baseAddress! + total, size - total)
            }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }   // shorter than fstat said: the file was truncated meanwhile
            total += n
        }
        data.count = total
        let stamp = Stamp(dev: st.st_dev, ino: st.st_ino, mtimeSec: st.st_mtimespec.tv_sec,
                          mtimeNsec: st.st_mtimespec.tv_nsec, size: size)
        return .file(File(data: data, stamp: stamp))
    }

    /// The bytes, or nil when the file is absent or refused.
    public static func boundedUserFileRead(path: String, uid: uid_t, limit: Int) -> Data? {
        read(path: path, uid: uid, limit: limit).file?.data
    }
}

/// After a failed child spawn, hold its reason for `window` instead of spawning again: a child
/// that hangs costs the tick its whole timeout, so a persistent failure must not cost that
/// every 2 s (chrome pages spec §7).
public struct SpawnBackoff {
    public var window: TimeInterval
    private var lastFailure: (at: Date, reason: String)?

    public init(window: TimeInterval) { self.window = window }

    /// The last reason, while the window since that failure has not elapsed.
    public func heldReason(now: Date) -> String? {
        guard let lastFailure, now.timeIntervalSince(lastFailure.at) < window else { return nil }
        return lastFailure.reason
    }
    public mutating func failed(_ reason: String, at now: Date) { lastFailure = (now, reason) }
    public mutating func succeeded() { lastFailure = nil }
}
