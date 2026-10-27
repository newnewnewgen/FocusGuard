import Foundation
import FocusGuardCore

enum ConfigFile {
    /// Support dir is root:admin 0775 so an admin user can write config.json; the state dir is
    /// root-only so the fail-closed snapshot and clock anchor cannot be removed without sudo.
    static func ensureSupportDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.supportDir) {
            try fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o775, .groupOwnerAccountName: "admin"], ofItemAtPath: Paths.supportDir)
        if !fm.fileExists(atPath: Paths.stateDir) {
            try fm.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: false)
        }
        try fm.setAttributes([.posixPermissions: 0o700, .groupOwnerAccountName: "wheel"], ofItemAtPath: Paths.stateDir)
    }

    private static var lastDecodeError: String?

    /// nil on any failure; the caller falls back to last-good. Decode errors are logged once per
    /// distinct message, not every tick.
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
        FileManager.default.createFile(atPath: Paths.lastGood, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Clock-guard anchor, root-only. Only meaningful within one boot; ClockGuard discards it
    /// itself when the boot-session tag no longer matches.
    static func loadClockState() -> ClockGuard.State? {
        guard let data = FileManager.default.contents(atPath: Paths.clockState) else { return nil }
        return try? JSONDecoder().decode(ClockGuard.State.self, from: data)
    }

    static func saveClockState(_ state: ClockGuard.State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        FileManager.default.createFile(atPath: Paths.clockState, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
