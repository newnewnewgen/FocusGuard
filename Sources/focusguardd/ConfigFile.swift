import Foundation
import FocusGuardCore

enum ConfigFile {
    /// The support dir is root:admin 0775 so the app can save config.json without a password.
    /// Everything the daemon trusts lives in the state dir under /var/db: root-owned, and in a
    /// parent the user cannot write, so it cannot be renamed aside or replaced without sudo.
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
        migrateLegacyState()
    }

    /// Before 0.4.0 the state dir sat inside the user-writable support dir. Carry the accepted
    /// config over once (so an update cannot be used to drop an active lock), then remove the old
    /// copies. The clock anchor is not carried: it is only valid within one daemon lineage and
    /// the guard re-anchors on its first sample.
    private static func migrateLegacyState() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.legacyStateDir) else { return }
        let old = Paths.legacyStateDir + "/last-good.json"
        if !fm.fileExists(atPath: Paths.lastGood), let data = fm.contents(atPath: old),
           (try? Config.decodeJSON(data)) != nil {
            writeRootFile(Paths.lastGood, data, mode: 0o644)
        }
        try? fm.removeItem(atPath: Paths.legacyStateDir)
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

    static func saveLastGood(_ config: Config) {
        guard let data = try? config.encodeJSON() else { return }
        writeRootFile(Paths.lastGood, data, mode: 0o644)
    }

    /// Clock-guard anchor, root-only. Only meaningful within one boot; ClockGuard discards it
    /// itself when the boot-session tag no longer matches.
    static func loadClockState() -> ClockGuard.State? {
        guard let data = FileManager.default.contents(atPath: Paths.clockState) else { return nil }
        return try? JSONDecoder().decode(ClockGuard.State.self, from: data)
    }

    static func saveClockState(_ state: ClockGuard.State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        writeRootFile(Paths.clockState, data, mode: 0o600)
    }

    static func saveStatus(_ status: DaemonStatus) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        writeRootFile(Paths.status, data, mode: 0o644)
    }

    /// Temp file + rename so a reader (the app watches status.json) never sees a partial file.
    /// The mode is set explicitly: `createFile` applies the umask to the attribute it is given.
    private static func writeRootFile(_ path: String, _ data: Data, mode: Int) {
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data) else { return }
        chmod(tmp, mode_t(mode))
        if rename(tmp, path) != 0 { unlink(tmp) }
    }
}
