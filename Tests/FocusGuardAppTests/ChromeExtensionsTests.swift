import XCTest
@testable import FocusGuard

final class ChromeExtensionsTests: XCTestCase {
    private var root: URL!
    let a = String(repeating: "a", count: 32)
    let b = String(repeating: "b", count: 32)
    let c = String(repeating: "c", count: 32)
    let d = String(repeating: "d", count: 32)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusguard-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Writes `<profile>/Extensions/<id>/<version>/manifest.json` (+ locales) under the fixture root.
    private func install(_ id: String, version: String, profile: String = "Default", manifest: [String: Any],
                         locales: [String: [String: Any]] = [:]) throws {
        let dir = root.appendingPathComponent("\(profile)/Extensions/\(id)/\(version)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for (locale, messages) in locales {
            let l = dir.appendingPathComponent("_locales/\(locale)")
            try FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: messages).write(to: l.appendingPathComponent("messages.json"))
        }
    }

    func testPlainNameAndSortedByName() throws {
        try install(a, version: "3.0.5_0", manifest: ["name": "News Feed Eradicator"])
        try install(b, version: "1.0_0", manifest: ["name": "Another"])
        let found = ChromeExtensions.installed(under: root)
        XCTAssertEqual(found.map(\.name), ["Another", "News Feed Eradicator"])
        XCTAssertEqual(found.map(\.id), [b, a])
    }

    func testMessageNameResolvedFromDefaultLocaleThenEnThenEnUS() throws {
        try install(a, version: "1_0", manifest: ["name": "__MSG_name__", "default_locale": "fr"],
                    locales: ["fr": ["name": ["message": "Pince-notes"]], "en": ["name": ["message": "Web Clipper"]]])
        try install(b, version: "1_0", manifest: ["name": "__MSG_extName__", "default_locale": "en_US"],
                    locales: ["en_US": ["extName": ["message": "Docs Offline"]]])
        try install(c, version: "1_0", manifest: ["name": "__MSG_appName__"],
                    locales: ["en": ["APPNAME": ["message": "Case Insensitive Key"]]])
        try install(d, version: "1_0", manifest: ["name": "__MSG_missing__"])
        let byID = Dictionary(uniqueKeysWithValues: ChromeExtensions.installed(under: root).map { ($0.id, $0.name) })
        XCTAssertEqual(byID[a], "Pince-notes")
        XCTAssertEqual(byID[b], "Docs Offline")
        XCTAssertEqual(byID[c], "Case Insensitive Key")
        XCTAssertEqual(byID[d], d, "falls back to the id")
    }

    func testNewestVersionWinsAndProfilesMerge() throws {
        try install(a, version: "1.6.0_0", manifest: ["name": "Old"])
        try install(a, version: "1.11_0", manifest: ["name": "New"])
        try install(a, version: "1.11_0", profile: "Profile 1", manifest: ["name": "New"])
        let found = ChromeExtensions.installed(under: root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].name, "New")
        XCTAssertEqual(found[0].profiles, ["Default", "Profile 1"])
    }

    func testNonExtensionEntriesAreSkipped() throws {
        try install(a, version: "1_0", manifest: ["name": "Real"])
        try install("Temp", version: "1_0", manifest: ["name": "Not an id"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Extensions/\(b)/.DS_Store-ish"), withIntermediateDirectories: true)
        XCTAssertEqual(ChromeExtensions.installed(under: root).map(\.id), [a])
        XCTAssertEqual(ChromeExtensions.installed(under: root.appendingPathComponent("missing")), [])
    }

    func testPatternsForAnExtension() {
        XCTAssertEqual(ChromeExtensions.patterns(forExtensionID: a), ["chrome-extension://\(a)/*", "chrome://extensions/*"])
        XCTAssertTrue(ChromeExtensions.isExtensionID("fjcldmjmjhkklehbacihaiopjklihlgg"))
        XCTAssertFalse(ChromeExtensions.isExtensionID("fjcldmjmjhkklehbacihaiopjklihlgq"), "q is outside a–p")
        XCTAssertTrue(ChromeExtensions.versionLess("1.6.0_0", "1.11_0"))
    }
}
