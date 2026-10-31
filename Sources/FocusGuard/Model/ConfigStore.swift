import Foundation
import FocusGuardCore

/// Reads and writes `config.json` as the logged-in admin user. Saves are temp-file + rename in the
/// same directory (atomic for the daemon, which re-reads every tick). A vnode source reports
/// external edits; nothing polls.
final class ConfigStore {
    var onExternalChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?

    var supportDirExists: Bool { FileManager.default.fileExists(atPath: Paths.supportDir) }
    var configExists: Bool { FileManager.default.fileExists(atPath: Paths.config) }

    /// Missing file → empty config (fresh install). Malformed file → throws (caller shows it).
    func load() throws -> Config {
        defer { watch() }
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return .empty }
        return try Config.decodeJSON(data)
    }

    func save(_ config: Config) throws {
        let data = try config.encodeJSON()
        let tmp = Paths.supportDir + "/.config.json.tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o664]) else {
            throw StoreError.cannotWrite(Paths.supportDir)
        }
        guard rename(tmp, Paths.config) == 0 else {
            let code = errno
            unlink(tmp)
            throw StoreError.rename(String(cString: strerror(code)))
        }
    }

    enum StoreError: LocalizedError {
        case cannotWrite(String), rename(String)
        var errorDescription: String? {
            switch self {
            case .cannotWrite(let dir): return "Cannot write to \(dir). Install protection first (the daemon creates the folder), and make sure this user is an administrator."
            case .rename(let why): return "Could not replace config.json: \(why)"
            }
        }
    }

    /// Watch the file if it exists, else the directory (to see the file appear), else nothing.
    private func watch() {
        let path: String? = configExists ? Paths.config : (supportDirExists ? Paths.supportDir : nil)
        guard path != watchedPath else { return }
        source?.cancel()
        source = nil
        watchedPath = path
        guard let path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { watchedPath = nil; return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            // After a rename/delete our fd points at the old inode; forget it so load() re-watches.
            if s.data.contains(.delete) || s.data.contains(.rename) { self.watchedPath = nil }
            self.onExternalChange?()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
