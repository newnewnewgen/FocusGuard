import Foundation
import FocusGuardCore

struct EtcHostsStore: HostsFileStore {
    let path: String

    func read() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Write to a sibling temp file, then rename over the original so readers never see a partial file.
    func write(_ contents: String) throws {
        let tmp = path + ".focusguard.tmp"
        try contents.write(toFile: tmp, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp)
        if rename(tmp, path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "rename \(tmp) → \(path): \(String(cString: strerror(err)))"])
        }
    }
}
