import Darwin
import Foundation
import FocusGuardCore

struct EtcHostsStore: HostsFileStore {
    let path: String

    struct EncodingError: Error {}

    func read() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let s = String(data: data, encoding: .utf8) { return s }
        // A hosts file with stray Latin-1 bytes must not make the site layer permanently inert.
        guard let s = String(data: data, encoding: .isoLatin1) else { throw EncodingError() }
        return s
    }

    /// Write to a sibling temp file, flush it to stable storage, then rename over the original,
    /// so readers never see a partial file and a power loss cannot leave an empty /etc/hosts.
    func write(_ contents: String) throws {
        let tmp = path + ".focusguard.tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw posixError("open \(tmp)") }
        defer { close(fd) }
        guard fchmod(fd, 0o644) == 0 else { throw posixError("chmod \(tmp)") }

        let data = Data(contents.utf8)
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                guard n > 0 else { throw posixError("write \(tmp)") }
                off += n
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw posixError("fsync \(tmp)") }
        guard rename(tmp, path) == 0 else {
            let err = posixError("rename \(tmp) → \(path)")
            try? FileManager.default.removeItem(atPath: tmp)
            throw err
        }
    }

    private func posixError(_ what: String) -> Error {
        let err = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                       userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(err)))"])
    }
}
