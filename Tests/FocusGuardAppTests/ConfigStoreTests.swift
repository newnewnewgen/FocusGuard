import XCTest
import FocusGuardCore
@testable import FocusGuard

final class ConfigStoreTests: XCTestCase {
    private var dir: String!
    private var path: String { dir + "/config.json" }
    private let sample = Config(blockLists: [BlockList(name: "l", domains: ["x.com"], appBundleIDs: [])], schedules: [])

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "focusguard-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        chmod(path, 0o644)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func store() -> ConfigStore { ConfigStore(configPath: path, supportDir: dir) }

    /// Let queued main-queue work (the vnode event handler) run.
    private func drainMainQueue(_ seconds: TimeInterval = 0.3) {
        let done = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testMissingFileLoadsAsEmpty() throws {
        XCTAssertEqual(try store().load(), .empty)
    }

    func testSaveThenLoadRoundTrips() throws {
        let s = store()
        try s.save(sample)
        XCTAssertEqual(try s.load(), sample)
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o664, "the daemon (root) and the next save both need this mode")
    }

    func testSavingAConfigTheDaemonWouldRejectIsRefused() throws {
        var tooMany = sample
        tooMany.blockLists[0].domains = (0...Config.Limits.maxDomains).map { "d\($0).com" }
        XCTAssertThrowsError(try store().save(tooMany))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "nothing was written")
    }

    func testCorruptFileThrows() throws {
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store().load())
    }

    func testUnreadableFileThrowsInsteadOfLoadingAsEmpty() throws {
        // The data-loss bug: an unreadable file was treated as missing, loaded as an empty
        // config, and the next edit overwrote the real one.
        try store().save(sample)
        chmod(path, 0o000)
        try XCTSkipIf(FileManager.default.contents(atPath: path) != nil, "running as a user who can read mode-000 files")
        XCTAssertThrowsError(try store().load()) { error in
            XCTAssertTrue(error is ConfigStore.StoreError)
        }
    }

    func testOwnSaveIsNotReportedAsAnExternalChange() throws {
        let s = store()
        try s.save(sample)          // creates the file and arms the watch on it
        _ = try s.load()
        drainMainQueue()
        var external = 0
        s.onExternalChange = { external += 1 }
        var changed = sample
        changed.blockLists[0].domains.append("y.com")
        try s.save(changed)
        drainMainQueue()
        XCTAssertEqual(external, 0)
    }

    func testExternalEditIsReported() throws {
        let s = store()
        try s.save(sample)
        _ = try s.load()
        drainMainQueue()
        let reported = expectation(description: "external change")
        reported.assertForOverFulfill = false
        s.onExternalChange = { reported.fulfill() }
        try Config.empty.encodeJSON().write(to: URL(fileURLWithPath: path), options: .atomic)
        wait(for: [reported], timeout: 10)
    }

    func testExternalEditRestoringTheBytesWeLastWroteIsStillReported() throws {
        // A → (external) B → (external) A again. The store used to remember A forever and
        // swallow the last event, leaving the model on B.
        let s = store()
        try s.save(sample)
        _ = try s.load()
        drainMainQueue()
        let a = try sample.encodeJSON()

        let sawB = expectation(description: "external change to B")
        sawB.assertForOverFulfill = false
        s.onExternalChange = { _ = try? s.load(); sawB.fulfill() }   // load() re-arms the watch
        try Config.empty.encodeJSON().write(to: URL(fileURLWithPath: path), options: .atomic)
        wait(for: [sawB], timeout: 10)
        drainMainQueue()

        let sawA = expectation(description: "external change back to A")
        sawA.assertForOverFulfill = false
        s.onExternalChange = { _ = try? s.load(); sawA.fulfill() }
        try a.write(to: URL(fileURLWithPath: path), options: .atomic)
        wait(for: [sawA], timeout: 10)
        XCTAssertEqual(try s.load(), sample)
    }
}

final class InstallerQuotingTests: XCTestCase {
    func testShellQuotingSurvivesSpacesAndQuotes() {
        XCTAssertEqual(Installer.shellQuoted("/Applications/Focus Guard.app/x"), "'/Applications/Focus Guard.app/x'")
        XCTAssertEqual(Installer.shellQuoted("it's"), "'it'\\''s'")
    }

    func testAppleScriptQuotingEscapesBackslashesAndQuotes() {
        XCTAssertEqual(Installer.appleScriptQuoted("say \"hi\" \\ there"), "\"say \\\"hi\\\" \\\\ there\"")
    }
}
