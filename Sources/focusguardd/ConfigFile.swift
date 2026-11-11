import Foundation
import FocusGuardCore

enum ConfigFile {
    /// The support dir is root:admin 0775 so the app can save config.json without a password.
    /// Everything the daemon trusts lives in the state dir under /var/db: root-owned, and in a
    /// parent the user cannot write, so it cannot be renamed aside or replaced without sudo.
    /// (State left by ≤ 0.3 inside the support dir is carried over by the installer script, once.)
    static func ensureDirectories() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.supportDir) {
            try fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o775, .groupOwnerAccountName: "admin"], ofItemAtPath: Paths.supportDir)
        if !fm.fileExists(atPath: Paths.stateDir) {
            try fm.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: false)
        }
        try fm.setAttributes([.posixPermissions: 0o755, .ownerAccountName: "root", .groupOwnerAccountName: "wheel"],
                             ofItemAtPath: Paths.stateDir)
    }

    private static var lastDecodeError: String?

    /// nil on any failure; the caller falls back to the accepted config. Decode errors are logged
    /// once per distinct message, not every tick.
    static func load(log: ReconcilerLog) -> Config? {
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return nil }
        do {
            let config = try Config.decodeJSON(data)
            if lastDecodeError != nil {
                lastDecodeError = nil
                log.info("config.json readable again")
            }
            return config
        } catch {
            let message = "\(error)"
            if message != lastDecodeError {
                lastDecodeError = message
                log.error("config.json unreadable: \(message)")
            }
            return nil
        }
    }

    static func loadLastGood() -> Config? {
        guard let data = FileManager.default.contents(atPath: Paths.lastGood) else { return nil }
        return try? Config.decodeJSON(data)
    }

    /// The save functions report whether the file was written, so a failed write is retried on
    /// the next tick instead of being remembered as done.
    @discardableResult
    static func saveLastGood(_ config: Config) -> Bool {
        guard let data = try? config.encodeJSON() else { return false }
        return writeRootFile(Paths.lastGood, data, mode: 0o644)
    }

    static func loadTimeZone() -> String? {
        FileManager.default.contents(atPath: Paths.timeZone).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @discardableResult
    static func saveTimeZone(_ identifier: String) -> Bool {
        writeRootFile(Paths.timeZone, Data(identifier.utf8), mode: 0o644)
    }

    /// Clock-guard anchor, root-only. Only meaningful within one boot; ClockGuard discards it
    /// itself when the boot-session tag no longer matches.
    static func loadClockState() -> ClockGuard.State? {
        guard let data = FileManager.default.contents(atPath: Paths.clockState) else { return nil }
        return try? JSONDecoder().decode(ClockGuard.State.self, from: data)
    }

    @discardableResult
    static func saveClockState(_ state: ClockGuard.State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return writeRootFile(Paths.clockState, data, mode: 0o600)
    }

    @discardableResult
    static func saveStatus(_ status: DaemonStatus) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(status) else { return false }
        return writeRootFile(Paths.status, data, mode: 0o644)
    }

    static func loadLearned() -> LearnedNames {
        guard let data = FileManager.default.contents(atPath: Paths.learned),
              let learned = try? JSONDecoder().decode(LearnedNames.self, from: data) else { return LearnedNames() }
        return learned
    }

    @discardableResult
    static func saveLearned(_ learned: LearnedNames) -> Bool {
        guard let data = try? JSONEncoder().encode(learned) else { return false }
        return writeRootFile(Paths.learned, data, mode: 0o644)
    }

    /// Temp file + rename so a reader (the app watches status.json) never sees a partial file.
    /// The mode is set explicitly: `createFile` applies the umask to the attribute it is given.
    static func writeRootFile(_ path: String, _ data: Data, mode: Int) -> Bool {
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data) else { return false }
        chmod(tmp, mode_t(mode))
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            return false
        }
        return true
    }
}
