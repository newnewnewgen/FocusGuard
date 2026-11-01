import AppKit
import Foundation

struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?
    /// Resolved once when the entry is created; rows must not hit LaunchServices per render.
    let icon: NSImage
    var id: String { bundleID }

    init(bundleID: String, name: String, url: URL?) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
        icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    static func == (a: AppEntry, b: AppEntry) -> Bool { a.bundleID == b.bundleID && a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(bundleID) }
}

/// App discovery for the picker and for block-list rows. `cache` is main-thread only; the
/// installed scan itself may run anywhere (it only reads the file system and bundle plists).
enum InstalledApps {
    /// Bundle ID → entry, filled by `running()`, `remember(_:)` and `entry(forBundleID:)`.
    @MainActor static var cache: [String: AppEntry] = [:]

    @MainActor
    static func running() -> [AppEntry] {
        let out = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppEntry? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return AppEntry(bundleID: id, name: app.localizedName ?? id, url: app.bundleURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        remember(out)
        return out
    }

    /// Scan the usual application folders, one level of vendor subfolders deep. Safe off the
    /// main thread; hand the result to `remember(_:)` on the main thread to populate the cache.
    static func installed() -> [AppEntry] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var out: [AppEntry] = []
        func scan(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    guard let id = Bundle(url: url)?.bundleIdentifier, !seen.contains(id) else { continue }
                    seen.insert(id)
                    out.append(AppEntry(bundleID: id, name: displayName(url), url: url))
                } else if depth > 0, !name.hasPrefix("."),
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    scan(url.path, depth: depth - 1)   // vendor folder, e.g. /Applications/Adobe
                }
            }
        }
        for root in roots { scan(root, depth: 1) }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func remember(_ entries: [AppEntry]) {
        for e in entries { cache[e.bundleID] = e }
    }

    /// For rows in a block list: resolve a stored bundle ID to a name and icon when the app is
    /// installed. Cached, so a row costs one LaunchServices lookup for the life of the process.
    @MainActor
    static func entry(forBundleID id: String) -> AppEntry {
        if let hit = cache[id] { return hit }
        let entry: AppEntry
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            entry = AppEntry(bundleID: id, name: displayName(url), url: url)
        } else {
            entry = AppEntry(bundleID: id, name: id, url: nil)
        }
        cache[id] = entry
        return entry
    }

    private static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
