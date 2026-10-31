import Foundation
import FocusGuardCore

/// Reads and writes `config.json` as the logged-in admin user. Saves are temp-file + rename in the
/// same directory (atomic for the daemon, which re-reads every tick). A vnode source reports
/// external edits; nothing polls.
///
/// Lifetime: one instance, owned by the single `AppModel`, alive for the whole process. That is why
/// the vnode source is the only thing torn down in `deinit` and nothing else unregisters observers.
final class ConfigStore {
    var onExternalChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    /// Bytes of the last successful save, so the vnode event our own rename raises is not
    /// reported as an external change.
    private var lastWritten: Data?

    private static let supportParent = (Paths.supportDir as NSString).deletingLastPathComponent

    var supportDirExists: Bool { FileManager.default.fileExists(atPath: Paths.supportDir) }
    var configExists: Bool { FileManager.default.fileExists(atPath: Paths.config) }

    deinit { source?.cancel() }

    /// Missing file → empty config (fresh install). Malformed file → throws (caller shows it).
    func load() throws -> Config {
        defer { watch() }
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return .empty }
        return try Config.decodeJSON(data)
    }

    func save(_ config: Config) throws {
        defer { watch() }
        let data = try config.encodeJSON()
        let tmp = Paths.supportDir + "/.config.json.\(getpid()).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o664]) else {
            unlink(tmp)
            throw StoreError.cannotWrite(Paths.supportDir)
        }
        guard rename(tmp, Paths.config) == 0 else {
            let code = errno
            unlink(tmp)
            throw StoreError.rename(String(cString: strerror(code)))
        }
        lastWritten = data
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

    /// Watch the file if it exists, else the support directory (to see the file appear), else
    /// `/Library/Application Support` (always present) to see the daemon create the directory.
    /// Each level up is re-watched one level down as soon as the next thing appears.
    private func watch() {
        let path = configExists ? Paths.config : (supportDirExists ? Paths.supportDir : Self.supportParent)
        guard path != watchedPath else { return }
        source?.cancel()
        source = nil
        watchedPath = path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { watchedPath = nil; return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            // After a rename/delete our fd points at the old inode; forget it so load() re-watches.
            if s.data.contains(.delete) || s.data.contains(.rename) { self.watchedPath = nil }
            // Our own save raises a rename on the old inode; the file now holds exactly what we
            // wrote, so there is nothing to reload — just re-arm on the new inode.
            if let last = self.lastWritten, FileManager.default.contents(atPath: Paths.config) == last {
                self.watch()
                return
            }
            self.onExternalChange?()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
