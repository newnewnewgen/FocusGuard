import Foundation

/// An extension installed in some Chrome profile on this Mac, read from its unpacked manifest.
struct ChromeExtension: Identifiable, Hashable {
    let id: String
    let name: String
    /// Profile folders it was found in ("Default", "Profile 1"), sorted.
    let profiles: [String]

    var patterns: [String] { ChromeExtensions.patterns(forExtensionID: id) }
}

/// Reads `~/Library/Application Support/Google/Chrome/*/Extensions/<id>/<version>/manifest.json`
/// (chrome pages spec §6). Read-only; safe off the main thread.
enum ChromeExtensions {
    static let chromeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome")

    /// The extension's own pages, and the page where it could be disabled.
    static func patterns(forExtensionID id: String) -> [String] {
        ["chrome-extension://\(id)/*", "chrome://extensions/*"]
    }

    static func installed() -> [ChromeExtension] { installed(under: chromeRoot) }

    static func installed(under root: URL) -> [ChromeExtension] {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var byID: [String: (name: String, profiles: [String])] = [:]
        for profile in profiles.sorted() {
            let extensions = root.appendingPathComponent(profile).appendingPathComponent("Extensions")
            guard let ids = try? fm.contentsOfDirectory(atPath: extensions.path) else { continue }
            for id in ids where isExtensionID(id) {
                let dir = extensions.appendingPathComponent(id)
                guard let versions = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                // Chrome keeps the previous version until the next launch; show the newest.
                let candidates = versions.filter { !$0.hasPrefix(".") }.sorted { versionLess($1, $0) }
                guard let (manifest, versionDir) = candidates.lazy.compactMap({ v -> ([String: Any], URL)? in
                    let d = dir.appendingPathComponent(v)
                    return readJSON(d.appendingPathComponent("manifest.json")).map { ($0, d) }
                }).first else { continue }
                let name = resolveName(manifest, in: versionDir) ?? id
                if let seen = byID[id] {
                    byID[id] = (seen.name, seen.profiles + [profile])
                } else {
                    byID[id] = (name, [profile])
                }
            }
        }
        return byID.map { ChromeExtension(id: $0.key, name: $0.value.name, profiles: $0.value.profiles) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Chrome extension ids are 32 letters in a–p (a hex digest spelled with letters).
    static func isExtensionID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    /// "1.6.0_0" < "1.11_0": numeric components compared in order.
    static func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.split(whereSeparator: { $0 == "." || $0 == "_" }).map { Int($0) ?? 0 }
        let pb = b.split(whereSeparator: { $0 == "." || $0 == "_" }).map { Int($0) ?? 0 }
        return pa.lexicographicallyPrecedes(pb)
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `name`, with `__MSG_key__` resolved from `_locales/<default_locale>/messages.json`, then
    /// `en`, then `en_US`; keys are matched exactly, then case-insensitively (Chrome treats
    /// them so). nil when nothing usable is found.
    static func resolveName(_ manifest: [String: Any], in dir: URL) -> String? {
        guard let raw = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2))
        var locales = ["en", "en_US"]
        if let def = manifest["default_locale"] as? String, !def.isEmpty { locales.insert(def, at: 0) }
        for locale in locales {
            guard let messages = readJSON(dir.appendingPathComponent("_locales/\(locale)/messages.json")) else { continue }
            let entry = messages[key] ?? messages.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            if let message = (entry as? [String: Any])?["message"] as? String,
               !message.trimmingCharacters(in: .whitespaces).isEmpty {
                return message.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
