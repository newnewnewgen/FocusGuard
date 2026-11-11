import CoreFoundation
import Darwin
import Foundation
import FocusGuardCore
import SystemConfiguration

/// Chrome's `URLBlocklist` policy as a CFPreferences write (chrome pages spec §3).
///
/// The durable copy is the **system domain**: `kCFPreferencesAnyUser` + `kCFPreferencesAnyHost`,
/// which is the plain file `/Library/Preferences/com.google.Chrome.plist` (`kCFPreferencesCurrentHost`
/// would be `/Library/Preferences/ByHost/…`, which Chrome does not read). The directory is
/// `root:wheel 0755`, so changing it without a password is impossible — the same guarantee as the
/// hosts region. Written in-process (`CFPreferencesSetValue` + `CFPreferencesSynchronize`): a
/// cfprefsd round trip, no shelling out.
///
/// Both domains are written, as decided by `scripts/probe-chrome-policy.sh` on 2026-11-11: Chrome
/// picks up a key *added* to the system file within 15 s but does not notice its *removal* within
/// 60 s, so the system domain alone would start windows on time and never end them. The console
/// user's domain (`~/Library/Preferences/com.google.Chrome.plist`, which Chrome watches live) is
/// therefore mirrored, as that user: cfprefsd keys the user domain by uid, so the daemon writes
/// the patterns to `Paths.chromeUserImport` and runs
/// `launchctl asuser <uid> sudo -n -H -u '#<uid>' defaults import com.google.Chrome <that file>`
/// (`delete` to remove). `launchctl asuser` alone only switches the Mach bootstrap context and
/// would leave `defaults` running as root with root's home; `sudo -u` (root to user, no password)
/// makes it the user's write. `import` rather than `write -array` because `write` parses each
/// element as a plist literal and rejects legal patterns containing `( ) { } [ ] < > "` or commas.
/// A user can delete their copy, which makes Chrome reload policy and find the system copy;
/// `userCopyPresent` notices it is gone and the Reconciler re-asserts it on that tick.
///
/// **The daemon is root and the user's plist is the user's.** It is never read with
/// `FileManager.contents(atPath:)`, which follows symlinks anywhere and blocks forever on a FIFO
/// — a `mkfifo ~/Library/Preferences/com.google.Chrome.plist` would stop every tick, including
/// the one that handles SIGTERM. `BoundedUserFile` opens with `O_NOFOLLOW|O_NONBLOCK`, checks the
/// descriptor is a regular file of that uid under 1 MiB, and reads at most that. Anything else is
/// "cannot tell", which counts as present: a planted file never causes a write.
///
/// The ownership record `Paths.chromePolicy` holds the patterns last written and the uid whose
/// domain mirrors them, so a restarted daemon knows the key is its own to update or remove, and
/// removes it from the user it wrote it for; it never touches a key without a record.
struct CFChromePolicyWriter: ChromePolicyWriter {
    /// Variant B of the plan's Task 4 table (write both domains), per the probe's VERDICT.
    static let alsoWritesUserDomain = true

    static let domain = "com.google.Chrome" as CFString
    static let key = "URLBlocklist" as CFString

    /// How long the user-domain child (`launchctl asuser … defaults`) may run before it is killed.
    /// A hung child must never block the tick: the write is retried next tick anyway.
    static let userDomainTimeout: TimeInterval = 10
    /// After a failed child, no child is spawned again for this long: a persistent failure
    /// costs one timeout per window, not one per 2 s tick (spec §7).
    static let spawnBackoff: TimeInterval = 30
    /// A user's Chrome plist larger than this is not read: it is not one Chrome wrote.
    static let userPlistLimit = 1 << 20

    private let log: ReconcilerLog?

    init(log: ReconcilerLog? = nil) {
        self.log = log
    }

    // MARK: ChromePolicyWriter

    /// A record that exists but cannot be decoded is still a record: the key is ours, its
    /// contents unknown, so an empty set is returned and the next apply or clear replaces it.
    func recordedPatterns() -> [String]? {
        switch Self.loadRecord() {
        case .absent: return nil
        case .undecodable: return []
        case .record(let record): return record.patterns
        }
    }

    /// The system domain only (the foreign-key rule's input): a user's own copy of the key in
    /// their domain is not a reason to refuse the durable one, which they cannot set.
    func keyIsPresent() -> Bool {
        CFPreferencesCopyValue(Self.key, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) != nil
    }

    /// The console user's plist, read directly (no process spawn; `defaults` flushes it at once
    /// so the file is current) under the bounded-read guard. The parse is cached by the opened
    /// file's identity (dev, inode, mtime, size), so an unchanged file costs one open+fstat per
    /// tick. With no console user there is no copy to keep: true, so nothing is retried until
    /// someone logs in and the next tick sees their file. A file the guard refuses is "cannot
    /// tell", also true, and logged once per distinct reason.
    func userCopyPresent() -> Bool {
        guard Self.alsoWritesUserDomain, let user = Self.consoleUser() else { return true }
        switch userCopy(uid: user.uid) {
        case .present, .unknown: return true
        case .absent: return false
        }
    }

    /// Order matters for a restart mid-write: the record is saved first, before either domain
    /// is touched, so no step that fails after it (retried next tick; `apply` is idempotent)
    /// can leave a key of ours that a restarted daemon would take for someone else's. The
    /// record is the intent: one with no key behind it is harmless, as `clear` on an absent key
    /// is a no-op. A record naming a *different* user's domain (or a `staleMirrorUID` from an
    /// earlier such failure) means that user's copy is ours to remove too. The console user is
    /// served first — the record (which already names the other user as `staleMirrorUID`), the
    /// durable copy and their mirror — and only then is the other user's copy removed: a failed
    /// removal arms the spawn backoff, and done first it would hold the console user's mirror
    /// for a window. If it fails the record keeps naming them so `clear` and the uninstall
    /// script try again, and their leftover is logged once; it reaches the status line only
    /// through the backoff, if a write is wanted within its window.
    ///
    /// During the spawn backoff (spec §7) nothing is touched: the held reason is returned before
    /// the record, the system domain or the import plist, so a persistent child failure costs
    /// one timeout per window, not a record save and a cfprefsd round trip per tick.
    func apply(patterns: [String]) -> String? {
        if let held = Self.heldReason() { return held }
        let console = Self.consoleUser()
        let previous = Self.loadRecord()
        var others: [uid_t] = []
        var previousUser: (name: String, uid: uid_t)?
        if Self.alsoWritesUserDomain, case .record(let record) = previous {
            others = Self.otherMirrors(of: record, console: console?.uid)
            if let uid = record.uid, let name = record.name { previousUser = (name, uid) }
        }
        var record = ChromePolicyRecord(patterns: patterns, writtenAt: Date(),
                                        uid: Self.alsoWritesUserDomain ? console?.uid : nil,
                                        name: Self.alsoWritesUserDomain ? console?.name : nil,
                                        staleMirrorUID: others.first)
        guard saveRecord(record, unless: previous) else { return "could not write \(Paths.chromePolicy)" }
        CFPreferencesSetValue(Self.key, patterns as CFArray, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            return "CFPreferencesSynchronize failed for the system domain"
        }
        if Self.alsoWritesUserDomain, let console, let reason = importUserDomain(patterns, uid: console.uid) { return reason }
        var stale: uid_t?
        for uid in others {
            guard let reason = deleteUserDomain(uid: uid) else { continue }
            if stale == nil { stale = uid }
            if Self.shouldLogStale(uid: uid) {
                let who = previousUser?.uid == uid ? "\(previousUser!.name) (#\(uid))" : "#\(uid)"
                log?.error("chrome: previous user \(who): \(reason); their copy is retried when the key is cleared")
            }
        }
        if stale != record.staleMirrorUID {
            record.staleMirrorUID = stale
            _ = saveRecord(record, unless: .absent)   // best effort: the key is already in place
        }
        return nil
    }

    /// The record goes last here, for the same reason: while any copy of the key may still be
    /// ours, the record must say so. The user copy is removed from the domain the record names
    /// (the console user's for a record from before the field existed) and from a stale mirror
    /// the record remembers, and the record is kept — retried next tick — until a bounded read
    /// of each user's plist shows the key gone.
    func clear() -> String? {
        if let held = Self.heldReason() { return held }
        CFPreferencesSetValue(Self.key, nil, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            return "CFPreferencesSynchronize failed for the system domain"
        }
        if Self.alsoWritesUserDomain {
            var targets: [uid_t] = []
            if case .record(let record) = Self.loadRecord() {
                if let uid = record.uid { targets.append(uid) }
                if let stale = record.staleMirrorUID, !targets.contains(stale) { targets.append(stale) }
            }
            // Neither a recorded user nor a console user: nothing was mirrored, nothing to remove.
            if targets.isEmpty, let console = Self.consoleUser() { targets.append(console.uid) }
            for uid in targets {
                if let reason = deleteUserDomain(uid: uid) { return reason }
            }
        }
        if unlink(Paths.chromePolicy) != 0, errno != ENOENT { return "could not remove \(Paths.chromePolicy)" }
        return nil
    }

    /// `/Applications/Google Chrome.app` or the console user's `~/Applications/Google Chrome.app`
    /// (the daemon's own home is root's). Two stats, and only on a tick that has patterns.
    var chromeInstalled: Bool {
        var candidates = ["/Applications/Google Chrome.app"]
        if let user = Self.consoleUser(), let home = Self.homeDirectory(uid: user.uid) {
            candidates.append(home + "/Applications/Google Chrome.app")
        }
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Record

    private enum RecordState {
        case absent
        case undecodable
        case record(ChromePolicyRecord)
    }

    private static func loadRecord() -> RecordState {
        guard let data = FileManager.default.contents(atPath: Paths.chromePolicy) else {
            return FileManager.default.fileExists(atPath: Paths.chromePolicy) ? .undecodable : .absent
        }
        guard let record = ChromePolicyRecord.decode(data) else { return .undecodable }
        return .record(record)
    }

    /// Mirrors the record names other than the console user's: the previous user when the
    /// console changed, and a stale one remembered from an earlier failed removal.
    private static func otherMirrors(of record: ChromePolicyRecord, console: uid_t?) -> [uid_t] {
        var uids: [uid_t] = []
        for uid in [record.uid, record.staleMirrorUID].compactMap({ $0 }) where uid != console && !uids.contains(uid) {
            uids.append(uid)
        }
        return uids
    }

    /// Writes `record` unless `existing` already says the same thing (`writtenAt` aside): a
    /// re-assert of an unchanged set is then no file write at all.
    private func saveRecord(_ record: ChromePolicyRecord, unless existing: RecordState) -> Bool {
        if case .record(let current) = existing, current.patterns == record.patterns, current.uid == record.uid,
           current.name == record.name, current.staleMirrorUID == record.staleMirrorUID {
            return true
        }
        guard let data = record.encode() else { return false }
        return ConfigFile.writeRootFile(Paths.chromePolicy, data, mode: 0o644)
    }

    /// One log line per stale user, however many applies find their copy still there.
    private static let staleLock = NSLock()
    private static var staleLogged: uid_t?
    private static func shouldLogStale(uid: uid_t) -> Bool {
        staleLock.lock(); defer { staleLock.unlock() }
        guard staleLogged != uid else { return false }
        staleLogged = uid
        return true
    }

    // MARK: User copy

    private enum UserCopy {
        case present
        case absent
        case unknown
    }

    /// One parse per distinct identity of the user's plist; see `userCopyPresent`.
    private final class UserPlistCache {
        private let lock = NSLock()
        private var key: (uid: uid_t, stamp: BoundedUserFile.Stamp)?
        private var present = false
        private var loggedRefusal: String?

        func lookup(uid: uid_t, stamp: BoundedUserFile.Stamp) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            guard let key, key.uid == uid, key.stamp == stamp else { return nil }
            return present
        }
        func remember(uid: uid_t, stamp: BoundedUserFile.Stamp, present: Bool) {
            lock.lock(); defer { lock.unlock() }
            key = (uid, stamp)
            self.present = present
        }
        func forget() {
            lock.lock(); defer { lock.unlock() }
            key = nil
        }
        /// True the first time `reason` is seen since the last distinct one.
        func shouldLog(refusal reason: String?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard reason != loggedRefusal else { return false }
            loggedRefusal = reason
            return reason != nil
        }
    }
    private static let userPlist = UserPlistCache()

    private func userCopy(uid: uid_t) -> UserCopy {
        guard let home = Self.homeDirectory(uid: uid) else { return .unknown }
        let path = home + "/Library/Preferences/com.google.Chrome.plist"
        switch BoundedUserFile.read(path: path, uid: uid, limit: Self.userPlistLimit) {
        case .absent:
            Self.userPlist.forget()
            _ = Self.userPlist.shouldLog(refusal: nil)
            return .absent
        case .refused(let why):
            Self.userPlist.forget()
            if Self.userPlist.shouldLog(refusal: why) {
                log?.error("chrome: not reading the user's Chrome plist (\(why)); assuming the copy is in place")
            }
            return .unknown
        case .file(let file):
            _ = Self.userPlist.shouldLog(refusal: nil)
            if let known = Self.userPlist.lookup(uid: uid, stamp: file.stamp) { return known ? .present : .absent }
            // Not a plist at all: Chrome cannot read it either, so the key is as good as absent.
            let present = ChromeUserImport.blocklistPresent(in: file.data) ?? false
            Self.userPlist.remember(uid: uid, stamp: file.stamp, present: present)
            return present ? .present : .absent
        }
    }

    // MARK: User-domain writes

    /// Writes `patterns` into the user's domain via `defaults import`. nil on success.
    private func importUserDomain(_ patterns: [String], uid: uid_t) -> String? {
        guard let plist = try? ChromeUserImport.plistData(patterns: patterns),
              ConfigFile.writeRootFile(Paths.chromeUserImport, plist, mode: 0o644) else {
            return "could not write \(Paths.chromeUserImport)"
        }
        switch Self.runDefaults(uid: uid, ["import", "com.google.Chrome", Paths.chromeUserImport], label: "defaults import") {
        case .failure(let held):
            return held.reason
        case .success(let exit):
            guard exit.status == 0 else {
                return Self.failed("defaults import (user domain) exited \(exit.status)\(exit.stderr.map { ": " + $0 } ?? "")")
            }
            Self.userPlist.forget()
            Self.succeeded()
            return nil
        }
    }

    /// `defaults delete` as the user, then proof: exit 1 means both "already absent" and
    /// "failed", so the user's plist is read (bounded) and the key must be gone. nil on success.
    private func deleteUserDomain(uid: uid_t) -> String? {
        let exit: Spawn.Exit
        switch Self.runDefaults(uid: uid, ["delete", "com.google.Chrome", "URLBlocklist"], label: "defaults delete") {
        case .failure(let held): return held.reason
        case .success(let e): exit = e
        }
        Self.userPlist.forget()
        let detail = "defaults delete exited \(exit.status)\(exit.stderr.map { ": " + $0 } ?? "")"
        switch userCopy(uid: uid) {
        case .absent:
            Self.succeeded()
            return nil
        case .present:
            return Self.failed("user copy still holds URLBlocklist (\(detail))")
        case .unknown:
            return Self.failed("cannot verify the user copy is gone (\(detail))")
        }
    }

    /// Backoff state shared by every write (spec §7): one failure holds all spawns for the window.
    private static let backoffLock = NSLock()
    private static var backoff = SpawnBackoff(window: spawnBackoff)

    private static func heldReason() -> String? {
        backoffLock.lock(); defer { backoffLock.unlock() }
        return backoff.heldReason(now: Date())
    }
    private static func failed(_ reason: String) -> String {
        backoffLock.lock(); defer { backoffLock.unlock() }
        backoff.failed(reason, at: Date())
        return reason
    }
    private static func succeeded() {
        backoffLock.lock(); defer { backoffLock.unlock() }
        backoff.succeeded()
    }

    private enum Spawn {
        struct Exit {
            var status: Int32
            /// First line of what the child wrote to stderr, if anything.
            var stderr: String?
        }
    }

    /// Runs `/usr/bin/defaults <args>` as `uid`, in that user's bootstrap, with the timeout and
    /// the backoff applied. `.failure` is a reason already recorded as a failure (held, could not
    /// launch, timed out); `.success` is an exit the caller judges.
    private static func runDefaults(uid: uid_t, _ args: [String], label: String) -> Result<Spawn.Exit, StringReason> {
        if let held = heldReason() { return .failure(StringReason(held)) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["asuser", String(uid), "/usr/bin/sudo", "-n", "-H", "-u", "#\(uid)", "/usr/bin/defaults"] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        // stderr is drained as it arrives: a blocking read after exit could wait on a pipe the
        // child handed to a grandchild, and a full pipe would otherwise stall the child.
        let stderr = Pipe()
        let captured = StderrBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                captured.append(chunk)
            }
        }
        p.standardError = stderr
        do {
            try p.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            return .failure(StringReason(failed("launchctl asuser: \(error.localizedDescription)")))
        }
        try? stderr.fileHandleForWriting.close()
        let finished = wait(for: p, timeout: userDomainTimeout)
        // The read end is closed when the Pipe goes away, not here: a handler call still in
        // flight must never find a closed descriptor.
        stderr.fileHandleForReading.readabilityHandler = nil
        // The handler runs on its own queue and may not have been scheduled for the child's
        // last write before it exited: one non-blocking drain so the exit reason is not lost.
        drain(stderr.fileHandleForReading.fileDescriptor, into: captured)
        guard finished else {
            return .failure(StringReason(failed("\(label) (user domain) timed out after \(Int(userDomainTimeout)) s")))
        }
        return .success(Spawn.Exit(status: p.terminationStatus, stderr: captured.firstLine))
    }

    /// Reads whatever is already in the pipe without waiting for more.
    private static func drain(_ fd: Int32, into buffer: StderrBuffer) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }   // 0: closed; EAGAIN: nothing more right now
            buffer.append(Data(chunk[0..<n]))
        }
    }

    private struct StringReason: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private final class StderrBuffer {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < 4096 { data.append(chunk.prefix(4096 - data.count)) }
        }
        var firstLine: String? {
            lock.lock(); defer { lock.unlock() }
            let text = String(decoding: data, as: UTF8.self)
            // `defaults` prefixes a timestamp and pid; the message is what follows the first "] ".
            let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            guard var line else { return nil }
            if let bracket = line.range(of: "] ") { line = String(line[bracket.upperBound...]) }
            return line.isEmpty ? nil : line
        }
    }

    /// Waits for `p` to exit, at most `timeout`. On expiry the child is terminated, then killed
    /// if it ignores that, and `false` is returned; the child is reaped either way so the daemon
    /// never accumulates zombies.
    private static func wait(for p: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if !p.isRunning {
            p.waitUntilExit()
            return true
        }
        p.terminate()
        let grace = Date().addingTimeInterval(1)
        while p.isRunning, Date() < grace {
            usleep(50_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        p.waitUntilExit()
        return false
    }

    // MARK: Users

    /// The user at the console (nil at the login window or when no one is logged in).
    static func consoleUser() -> (name: String, uid: uid_t)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", uid != 0 else { return nil }
        return (name, uid)
    }

    static func homeDirectory(uid: uid_t) -> String? {
        guard let pw = getpwuid(uid), let dir = pw.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.isEmpty ? nil : home
    }
}
