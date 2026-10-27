import Foundation
import FocusGuardCore

enum ConfigFile {
    /// Create the support dir as root:admin 0775 so an admin user can write config.json.
    static func ensureSupportDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.supportDir) {
            try fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o775, .groupOwnerAccountName: "admin"], ofItemAtPath: Paths.supportDir)
    }

    /// nil on any failure; the caller falls back to last-good.
    static func load(log: ReconcilerLog) -> Config? {
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return nil }
        do {
            return try Config.decodeJSON(data)
        } catch {
            log.error("config.json unreadable: \(error)")
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
    /// itself when the monotonic clock has gone backwards.
    static func loadClockState() -> ClockGuard.State? {
        guard let data = FileManager.default.contents(atPath: Paths.clockState) else { return nil }
        return try? JSONDecoder().decode(ClockGuard.State.self, from: data)
    }

    static func saveClockState(_ state: ClockGuard.State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        FileManager.default.createFile(atPath: Paths.clockState, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
