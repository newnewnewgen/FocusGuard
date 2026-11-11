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
/// therefore mirrored, as that user: cfprefsd keys the user domain by uid, so the daemon runs
/// `launchctl asuser <uid> sudo -n -u <name> defaults …`. `launchctl asuser` alone only switches
/// the Mach bootstrap context and would leave `defaults` running as root with root's home;
/// `sudo -u` (root to user, no password) makes it the user's write. A user can delete that copy,
/// which makes Chrome reload policy and find the system copy; the next tick re-asserts it anyway.
///
/// The ownership record `Paths.chromePolicy` holds the patterns last written, so a restarted
/// daemon knows the key is its own to update or remove; it never touches a key without a record.
struct CFChromePolicyWriter: ChromePolicyWriter {
    /// Variant B of the plan's Task 4 table (write both domains), per the probe's VERDICT.
    static let alsoWritesUserDomain = true

    static let domain = "com.google.Chrome" as CFString
    static let key = "URLBlocklist" as CFString

    /// How long the user-domain child (`launchctl asuser … defaults`) may run before it is killed.
    /// A hung child must never block the tick: the write is retried next tick anyway.
    static let userDomainTimeout: TimeInterval = 10

    private struct Record: Codable {
        var patterns: [String]
        var writtenAt: Date
    }

    // MARK: ChromePolicyWriter

    func recordedPatterns() -> [String]? {
        guard let data = FileManager.default.contents(atPath: Paths.chromePolicy),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record.patterns
    }

    func keyIsPresent() -> Bool {
        if CFPreferencesCopyValue(Self.key, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) != nil { return true }
        guard Self.alsoWritesUserDomain, let user = Self.consoleUser(),
              let home = NSHomeDirectoryForUser(user.name) else { return false }
        // The user's plist read directly: cheap, no process spawn, and `defaults write` flushes
        // it at once so the file is current.
        guard let data = FileManager.default.contents(atPath: home + "/Library/Preferences/com.google.Chrome.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return false }
        return plist["URLBlocklist"] != nil
    }

    /// Order matters for a restart mid-write: the record is saved first, before either domain
    /// is touched, so no step that fails after it (retried next tick; `apply` is idempotent)
    /// can leave a key of ours that a restarted daemon would take for someone else's. The
    /// record is the intent: one with no key behind it is harmless, as `clear` on an absent key
    /// is a no-op.
    func apply(patterns: [String]) -> String? {
        guard saveRecord(patterns) else { return "could not write \(Paths.chromePolicy)" }
        CFPreferencesSetValue(Self.key, patterns as CFArray, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            return "CFPreferencesSynchronize failed for the system domain"
        }
        if Self.alsoWritesUserDomain, let reason = writeUserDomain(patterns) { return reason }
        return nil
    }

    /// The record goes last here, for the same reason: while any copy of the key may still be
    /// ours, the record must say so.
    func clear() -> String? {
        CFPreferencesSetValue(Self.key, nil, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            return "CFPreferencesSynchronize failed for the system domain"
        }
        if Self.alsoWritesUserDomain, let reason = writeUserDomain(nil) { return reason }
        if unlink(Paths.chromePolicy) != 0, errno != ENOENT { return "could not remove \(Paths.chromePolicy)" }
        return nil
    }

    /// `/Applications/Google Chrome.app` or the console user's `~/Applications/Google Chrome.app`
    /// (the daemon's own home is root's). Two stats, and only on a tick that has patterns.
    var chromeInstalled: Bool {
        var candidates = ["/Applications/Google Chrome.app"]
        if let user = Self.consoleUser(), let home = NSHomeDirectoryForUser(user.name) {
            candidates.append(home + "/Applications/Google Chrome.app")
        }
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Pieces

    private func saveRecord(_ patterns: [String]) -> Bool {
        guard let data = try? JSONEncoder().encode(Record(patterns: patterns, writtenAt: Date())) else { return false }
        return ConfigFile.writeRootFile(Paths.chromePolicy, data, mode: 0o644)
    }

    /// The user at the console (nil at the login window or when no one is logged in).
    static func consoleUser() -> (name: String, uid: uid_t)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", uid != 0 else { return nil }
        return (name, uid)
    }

    /// `patterns == nil` deletes the key. Returns a reason on failure; with no console user the
    /// write cannot be done yet, which is reported so the tick retries it once someone is logged
    /// in (Chrome is not running for anyone meanwhile).
    private func writeUserDomain(_ patterns: [String]?) -> String? {
        guard let user = Self.consoleUser() else { return "no console user for the user-domain write" }
        var args = ["asuser", String(user.uid), "/usr/bin/sudo", "-n", "-u", user.name, "/usr/bin/defaults"]
        if let patterns {
            args += ["write", "com.google.Chrome", "URLBlocklist", "-array"] + patterns
        } else {
            args += ["delete", "com.google.Chrome", "URLBlocklist"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return "launchctl asuser: \(error.localizedDescription)"
        }
        guard Self.wait(for: p, timeout: Self.userDomainTimeout) else {
            return "defaults \(patterns == nil ? "delete" : "write") (user domain) timed out after \(Int(Self.userDomainTimeout)) s"
        }
        // `defaults delete` exits 1 when the key is already absent — the state we want.
        guard patterns == nil || p.terminationStatus == 0 else {
            return "defaults write (user domain) exited \(p.terminationStatus)"
        }
        return nil
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
}
