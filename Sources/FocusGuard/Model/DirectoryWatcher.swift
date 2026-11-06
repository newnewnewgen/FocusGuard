import Foundation

/// Calls back on the main queue when an entry in a directory is created, replaced or removed.
/// Used for the daemon's state directory, whose files are replaced by rename (which a watch on
/// the file itself would lose). Event-driven; nothing polls.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    /// nil when the directory does not exist (yet).
    init?(path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
