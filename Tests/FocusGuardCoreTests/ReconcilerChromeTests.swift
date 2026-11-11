import XCTest
@testable import FocusGuardCore

final class ReconcilerChromeTests: XCTestCase {
    let base = "127.0.0.1 localhost\n"
    let ext = "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*"
    let page = "chrome://extensions/*"
    lazy var a = BlockList(name: "a", chromeURLs: [page, ext])
    lazy var b = BlockList(name: "b", chromeURLs: [ext, "chrome://settings/*"])
    lazy var cfg = Config(blockLists: [a, b], schedules: [
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [a.id, b.id])])
    /// Sorted union: what the writer must receive. "-" sorts before ":", so the extension
    /// pattern comes first.
    lazy var all = [ext, "chrome://extensions/*", "chrome://settings/*"]

    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }()
    func monday(_ h: Int, _ m: Int) -> Date {   // 2026-10-26 is a Monday
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m))!
    }

    var hosts: FakeHosts!
    var chrome: RecordingChromePolicyWriter!
    var log: FakeLog!
    var sut: Reconciler!

    override func setUp() {
        hosts = FakeHosts(base)
        chrome = RecordingChromePolicyWriter()
        log = FakeLog()
        sut = Reconciler(hosts: hosts, dns: FakeDNS(), processes: FakeProcesses(), log: log, chrome: chrome, calendar: cal)
    }

    func testActiveSetUnionsPatternsOfActiveLists() {
        let inside = cfg.activeSet(at: LocalMoment(weekday: .mon, minutesSinceMidnight: 600))
        XCTAssertEqual(inside.chromeURLs, Set(all))
        XCTAssertFalse(inside.isEmpty)
        XCTAssertEqual(cfg.activeSet(at: LocalMoment(weekday: .mon, minutesSinceMidnight: 800)).chromeURLs, [])
        XCTAssertFalse(ActiveSet(domains: [], bundleIDs: [], chromeURLs: ["x"]).isEmpty)
        XCTAssertFalse(ActiveSet(domains: [], bundleIDs: [], chromeURLs: ["x"]).isSubset(of: .empty))
        XCTAssertEqual(Array(inside.chromeURLs).sorted(), all)
    }

    func testWindowStartWritesSortedPatternsOnceAndWindowEndClears() {
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(chrome.applied, [all])
        XCTAssertEqual(r.chrome, "applied (3 patterns)")
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(chrome.applied.count, 1, "unchanged set: no second write")
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(12, 0), monotonic: 7300))
        XCTAssertEqual(chrome.clears, 1)
        XCTAssertNil(chrome.present)
        XCTAssertEqual(r2.chrome, "off")
        XCTAssertTrue(log.infos.contains { $0.contains("chrome policy updated: 3") })
        XCTAssertTrue(log.infos.contains { $0.contains("chrome policy removed") })
    }

    func testAnEditedSetIsRewritten() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        var smaller = cfg
        smaller.blockLists[1].chromeURLs = []
        let r = sut.tick(live: smaller, clock: ClockSample(wall: monday(10, 1), monotonic: 160))
        XCTAssertEqual(chrome.applied.last, [page, ext].sorted())
        XCTAssertEqual(r.chrome, "applied (2 patterns)")
    }

    func testNothingIsWrittenWhileNothingIsWantedAndNothingWasEverWritten() {
        var plain = cfg
        plain.blockLists = [BlockList(name: "p", domains: ["x.com"])]
        plain.schedules[0].blockListIDs = [plain.blockLists[0].id]
        chrome.present = ["https://theirs.example"]   // someone else's, must survive untouched
        let r = sut.tick(live: plain, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "off")
        XCTAssertEqual(chrome.applied, [])
        XCTAssertEqual(chrome.clears, 0)
        XCTAssertEqual(chrome.present, ["https://theirs.example"])
    }

    func testForeignKeyIsLeftAloneAndLoggedOnce() {
        chrome.present = ["https://theirs.example"]
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "not applied (URLBlocklist already set by someone else)")
        XCTAssertEqual(chrome.applied, [])
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(log.errors.filter { $0.contains("already set by someone else") }.count, 1, "latched")
        // Once they remove it, FocusGuard takes over.
        chrome.present = nil
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r2.chrome, "applied (3 patterns)")
        XCTAssertEqual(chrome.applied, [all])
    }

    func testASecondForeignEpisodeIsLoggedAgain() {
        chrome.present = ["https://theirs.example"]
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        chrome.present = nil
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(chrome.applied.count, 1)
        // Window ends: our key is cleared. Then they set theirs before the next window.
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(12, 0), monotonic: 7300))
        XCTAssertEqual(chrome.clears, 1)
        chrome.present = ["https://theirs.example"]
        let nextMonday = cal.date(byAdding: .day, value: 7, to: monday(10, 0))!
        let r = sut.tick(live: cfg, clock: ClockSample(wall: nextMonday, monotonic: 100 + 7 * 86400))
        XCTAssertEqual(r.chrome, "not applied (URLBlocklist already set by someone else)")
        XCTAssertEqual(log.errors.filter { $0.contains("already set by someone else") }.count, 2, "a new episode")
    }

    func testRestartWithARecordOwnsTheKey() {
        // A previous daemon wrote these and the window is now over: clear.
        chrome.record = all
        chrome.present = all
        var plain = cfg
        plain.blockLists = []
        plain.schedules = []
        let r = sut.tick(live: plain, clock: ClockSample(wall: monday(13, 0), monotonic: 100))
        XCTAssertEqual(chrome.clears, 1)
        XCTAssertEqual(r.chrome, "off")
    }

    func testRestartWithARecordDoesNotRewriteAnIdenticalSet() {
        chrome.record = all
        chrome.present = all
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(chrome.applied, [], "already what we want")
        XCTAssertEqual(r.chrome, "applied (3 patterns)")
    }

    func testWriteFailureIsReportedLatchedAndRetried() {
        chrome.failWith = "cfprefsd said no"
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "error: cfprefsd said no")
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(log.errors.filter { $0.contains("chrome policy write failed") }.count, 1)
        chrome.failWith = nil
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r2.chrome, "applied (3 patterns)")
        XCTAssertTrue(log.infos.contains { $0.contains("chrome policy writes recovered") })
    }

    func testAFailedWriteThatSetTheKeyIsNotMistakenForAForeignKey() {
        chrome.failWith = "record unwritable"
        chrome.failLeavesKey = true
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "error: record unwritable")
        XCTAssertTrue(chrome.keyIsPresent())
        XCTAssertNil(chrome.recordedPatterns())
        let r1 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(r1.chrome, "error: record unwritable", "still ours to retry, not someone else's")
        chrome.failWith = nil
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r2.chrome, "applied (3 patterns)")
        XCTAssertEqual(chrome.applied, [all])
        XCTAssertTrue(log.errors.filter { $0.contains("already set by someone else") }.isEmpty)
    }

    func testADeletedUserCopyIsReassertedNextTick() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(chrome.applied.count, 1)
        chrome.userCopy = false
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(chrome.applied, [all, all], "written again, same set")
        XCTAssertEqual(r.chrome, "applied (3 patterns)")
        XCTAssertTrue(chrome.userCopyPresent())
        XCTAssertEqual(log.infos.filter { $0.contains("user copy was removed; re-asserted") }.count, 1)
        // Present again: no churn.
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 6), monotonic: 106))
        XCTAssertEqual(chrome.applied.count, 2)
    }

    func testAUserDeletingInALoopIsLoggedOncePerEpisode() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        for i in 1...3 {
            chrome.userCopy = false
            _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2 * i), monotonic: 100 + Double(2 * i)))
        }
        XCTAssertEqual(chrome.applied.count, 4, "every deletion is answered")
        XCTAssertEqual(log.infos.filter { $0.contains("user copy was removed; re-asserted") }.count, 1, "one episode")
        // A tick that finds it in place ends the episode; the next deletion is a new one.
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 8), monotonic: 108))
        chrome.userCopy = false
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 10), monotonic: 110))
        XCTAssertEqual(log.infos.filter { $0.contains("user copy was removed; re-asserted") }.count, 2)
    }

    func testUserCopyIsNotCheckedWhileNothingIsWanted() {
        chrome.userCopy = false
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(13, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "off")
        XCTAssertEqual(chrome.applied, [])
    }

    func testChromeNotFoundIsOnlyASuffix() {
        chrome.chromeInstalled = false
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "applied (3 patterns; Chrome not found)")
        XCTAssertEqual(chrome.applied, [all], "still written: Chrome installed later picks it up")
    }

    func testNoWriterMeansOffAndNoWrites() {
        let none = Reconciler(hosts: hosts, dns: FakeDNS(), processes: FakeProcesses(), log: log, calendar: cal)
        XCTAssertEqual(none.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100)).chrome, "off")
    }

    func testHeldConfigKeepsThePatternsItProtects() {
        var locked = cfg
        locked.schedules[0].unlockMode = .impossible
        _ = sut.tick(live: locked, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(chrome.applied.count, 1)
        var proposed = locked
        proposed.blockLists[0].chromeURLs = []
        proposed.blockLists[1].chromeURLs = []
        let r = sut.tick(live: proposed, clock: ClockSample(wall: monday(10, 1), monotonic: 160))
        XCTAssertEqual(r.source, .held)
        XCTAssertEqual(chrome.applied.count, 1, "the accepted set is still enforced: no rewrite")
        XCTAssertEqual(chrome.clears, 0)
        XCTAssertEqual(r.chrome, "applied (3 patterns)")
    }

    func testTeardownClearsOnlyOurOwnKey() {
        chrome.present = ["https://theirs.example"]
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        sut.teardown()
        XCTAssertEqual(chrome.clears, 0, "foreign key: not ours to remove")
        chrome.present = nil
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        sut.teardown()
        XCTAssertEqual(chrome.clears, 1)
        XCTAssertEqual(hosts.contents, base)
    }
}

private extension ReconcilerChromeTests {
    func monday(_ h: Int, _ m: Int, _ s: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m, second: s))!
    }
}
