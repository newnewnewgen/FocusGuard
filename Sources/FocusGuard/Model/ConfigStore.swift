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

    private let configPath: String
    private let supportDir: String
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    /// Bytes of a save whose vnode event has not arrived yet, so that one event is not reported as
    /// an external change. Cleared as soon as it has been matched: holding on to it would also
    /// swallow a later external edit that happened to restore the same bytes.
    private var pendingOwnWrite: Data?

    /// Paths are injectable for tests; the app uses the defaults.
    init(configPath: String = Paths.config, supportDir: String = Paths.supportDir) {
        self.configPath = configPath
        self.supportDir = supportDir
    }

    private var supportParent: String { (supportDir as NSString).deletingLastPathComponent }

    var supportDirExists: Bool { FileManager.default.fileExists(atPath: supportDir) }
    var configExists: Bool { FileManager.default.fileExists(atPath: configPath) }

    deinit { source?.cancel() }

    /// Missing file → empty config (fresh install). A file that exists but cannot be read, or
    /// does not parse, throws: the caller disables editing, so a config we could not see is never
    /// overwritten with an empty one.
    func load() throws -> Config {
        defer { watch() }
        guard configExists else { return .empty }
        guard let data = FileManager.default.contents(atPath: configPath) else { throw StoreError.unreadable(configPath) }
        return try Config.decodeJSON(data)
    }

    func save(_ config: Config) throws {
        defer { watch() }
        let data = try config.encodeJSON()
        let tmp = supportDir + "/.config.json.\(getpid()).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o664]) else {
            unlink(tmp)
            throw StoreError.cannotWrite(supportDir)
        }
        guard rename(tmp, configPath) == 0 else {
            let code = errno
            unlink(tmp)
            throw StoreError.rename(String(cString: strerror(code)))
        }
        pendingOwnWrite = data
    }

    enum StoreError: LocalizedError {
        case cannotWrite(String), rename(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .cannotWrite(let dir): return "Cannot write to \(dir). Install protection first (the daemon creates the folder), and make sure this user is an administrator."
            case .rename(let why): return "Could not replace config.json: \(why)"
            case .unreadable(let path): return "\(path) exists but this user cannot read it."
            }
        }
    }

    /// Watch the file if it exists, else the support directory (to see the file appear), else
    /// its parent (always present) to see the daemon create the directory. Each level up is
    /// re-watched one level down as soon as the next thing appears.
    private func watch() {
        let path = configExists ? configPath : (supportDirExists ? supportDir : supportParent)
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
            // After a rename/delete our fd points at the old inode; forget it so the next
            // load()/watch() re-arms on whatever is at the path now.
            if s.data.contains(.delete) || s.data.contains(.rename) { self.watchedPath = nil }
            self.handleEvent()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    /// Our own save raises one event on the inode it replaced; the file then holds exactly what
    /// we wrote and there is nothing to reload. Anything else is an external change.
    private func handleEvent() {
        if let own = pendingOwnWrite {
            pendingOwnWrite = nil
            if FileManager.default.contents(atPath: configPath) == own {
                watch()
                return
            }
        }
        onExternalChange?()
    }
}
