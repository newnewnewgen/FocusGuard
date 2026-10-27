import XCTest
@testable import FocusGuardCore

final class ReconcilerTests: XCTestCase {
    let base = "127.0.0.1 localhost\n"
    let list = BlockList(name: "l", domains: ["reddit.com"], appBundleIDs: ["com.example.slack"])
    lazy var cfg = Config(
        blockLists: [list],
        schedules: [ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])])

    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }()
    // 2026-10-26 is a Monday.
    func monday(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m))!
    }

    var hosts: FakeHosts!
    var dns: FakeDNS!
    var procs: FakeProcesses!
    var log: FakeLog!
    var sut: Reconciler!

    override func setUp() {
        hosts = FakeHosts(base)
        dns = FakeDNS()
        procs = FakeProcesses()
        log = FakeLog()
        sut = Reconciler(hosts: hosts, dns: dns, processes: procs, log: log, killGrace: 3, calendar: cal)
    }

    func testEnteringWindowWritesHostsAndFlushesOnce() {
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertTrue(r.hostsChanged)
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))
        XCTAssertEqual(dns.flushes, 1)
        XCTAssertEqual(r.source, .live)

        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertFalse(r2.hostsChanged)
        XCTAssertEqual(hosts.writes, 1)
        XCTAssertEqual(dns.flushes, 1)
    }

    func testLeavingWindowStripsRegion() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 59), monotonic: 100))
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(12, 0), monotonic: 160))
        XCTAssertTrue(r.hostsChanged)
        XCTAssertEqual(hosts.contents, base)
        XCTAssertTrue(r.activeSet.isEmpty)
    }

    func testBlockedAppIsTerminatedThenKilledAfterGrace() {
        procs.apps = [RunningApp(pid: 42, bundleID: "com.example.slack"), RunningApp(pid: 7, bundleID: "com.apple.Safari")]

        let r1 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r1.terminated, [42])
        XCTAssertEqual(r1.killed, [])

        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(r2.terminated, [], "no second SIGTERM inside the grace period")
        XCTAssertEqual(r2.killed, [])

        let r3 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r3.killed, [42])
        XCTAssertEqual(procs.terminated, [42])
        XCTAssertFalse(procs.killed.contains(7))
    }

    func testAppThatExitsAfterTermIsNotKilled() {
        procs.apps = [RunningApp(pid: 42, bundleID: "com.example.slack")]
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        procs.apps = []  // it quit politely
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r.killed, [])
        // Relaunch later gets a fresh SIGTERM, not an immediate SIGKILL.
        procs.apps = [RunningApp(pid: 43, bundleID: "com.example.slack")]
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 6), monotonic: 106))
        XCTAssertEqual(r2.terminated, [43])
    }

    func testNoKillsOutsideWindow() {
        procs.apps = [RunningApp(pid: 42, bundleID: "com.example.slack")]
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(13, 0), monotonic: 100))
        XCTAssertEqual(r.terminated, [])
        XCTAssertEqual(hosts.writes, 0)
        XCTAssertEqual(procs.enumerations, 0, "no process scan when no apps are blocked (battery)")
    }

    func testClockRewindDoesNotReleaseWindow() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        // User sets the clock back to 08:00 two seconds later.
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(8, 0), monotonic: 102))
        XCTAssertFalse(r.activeSet.isEmpty, "projected time is still 11:00:02")
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))
        XCTAssertEqual(log.errors.count, 1, "tamper logged once, not every tick")
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(8, 0, 2), monotonic: 104))
        XCTAssertEqual(log.errors.count, 1)
    }

    func testClockJumpForwardDoesNotReleaseWindow() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(14, 0), monotonic: 102))
        XCTAssertFalse(r.activeSet.isEmpty)
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))
    }

    func testClockStateIsExposedAndSeedable() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        let saved = sut.clockState
        XCTAssertNotNil(saved)
        // A restarted reconciler seeded with the saved state still resists a rewind.
        let restarted = Reconciler(hosts: hosts, dns: dns, processes: procs, log: log,
                                   clockState: saved, killGrace: 3, calendar: cal)
        let r = restarted.tick(live: cfg, clock: ClockSample(wall: monday(8, 0), monotonic: 102))
        XCTAssertFalse(r.activeSet.isEmpty)
    }

    func testConfigVanishingMidWindowKeepsBlockingUntilWindowEnds() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        let r = sut.tick(live: nil, clock: ClockSample(wall: monday(11, 30), monotonic: 1900))
        XCTAssertEqual(r.source, .lastGood)
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))

        let r2 = sut.tick(live: nil, clock: ClockSample(wall: monday(12, 1), monotonic: 3760))
        XCTAssertEqual(r2.source, .none)
        XCTAssertEqual(hosts.contents, base)
    }

    func testHostsReadFailureIsLoggedNotFatal() {
        hosts.failReads = true
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertFalse(r.hostsChanged)
        XCTAssertEqual(log.errors.count, 1)
    }

    func testTeardownStripsRegion() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        sut.teardown()
        XCTAssertEqual(hosts.contents, base)
        XCTAssertEqual(dns.flushes, 2)
    }
}

private extension ReconcilerTests {
    func monday(_ h: Int, _ m: Int, _ s: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m, second: s))!
    }
}
