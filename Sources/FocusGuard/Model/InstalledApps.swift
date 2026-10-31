import AppKit
import Foundation

struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?
    var id: String { bundleID }

    var icon: NSImage {
        url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

/// App discovery for the picker. Everything here runs only when the sheet opens.
enum InstalledApps {
    static func running() -> [AppEntry] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return AppEntry(bundleID: id, name: app.localizedName ?? id, url: app.bundleURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func installed() -> [AppEntry] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var out: [AppEntry] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard let id = Bundle(url: url)?.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(AppEntry(bundleID: id, name: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// For rows in a block list: resolve a stored bundle ID to a name and icon when the app is installed.
    static func entry(forBundleID id: String) -> AppEntry {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return AppEntry(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url)
        }
        return AppEntry(bundleID: id, name: id, url: nil)
    }
}
