import XCTest
@testable import FocusGuardCore

/// Changing the Mac's time zone moves no `Date`, so the clock guard cannot see it; but it moves
/// which local minute "now" is. The reconciler follows the system zone except during an
/// Impossible window.
final class ReconcilerZoneTests: XCTestCase {
    let vancouver = TimeZone(identifier: "America/Vancouver")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let base = "127.0.0.1 localhost\n"
    let list = BlockList(name: "l", domains: ["reddit.com"], appBundleIDs: [])

    func config(mode: UnlockMode) -> Config {
        Config(blockLists: [list], schedules: [ScheduleWindow(
            name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id], unlockMode: mode)])
    }

    /// 2026-10-26 is a Monday. Times are Vancouver wall-clock.
    func mondayVancouver(_ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = vancouver
        return cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m))!
    }

    var hosts: FakeHosts!
    var log: FakeLog!

    func makeReconciler(zone: TimeZone? = nil) -> Reconciler {
        hosts = FakeHosts(base)
        log = FakeLog()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = vancouver
        return Reconciler(hosts: hosts, dns: FakeDNS(), processes: FakeProcesses(), log: log, calendar: cal, zone: zone)
    }

    func testZoneChangeDuringAnImpossibleWindowIsHeldBack() {
        let r = makeReconciler()
        let cfg = config(mode: .impossible)
        _ = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 0), monotonic: 100), systemZone: vancouver)
        // 10:02 in Vancouver is 02:02 on Tuesday in Tokyo: outside the window if the zone were adopted.
        let out = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 2), monotonic: 220), systemZone: tokyo)
        XCTAssertFalse(out.activeSet.isEmpty, "still inside the window")
        XCTAssertEqual(out.timeZone, "America/Vancouver")
        XCTAssertEqual(log.errors.filter { $0.contains("time zone") }.count, 1)
        _ = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 4), monotonic: 340), systemZone: tokyo)
        XCTAssertEqual(log.errors.filter { $0.contains("time zone") }.count, 1, "latched")
    }

    func testHeldBackZoneIsAdoptedWhenTheWindowEnds() {
        let r = makeReconciler()
        let cfg = config(mode: .impossible)
        _ = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 0), monotonic: 100), systemZone: vancouver)
        _ = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 2), monotonic: 220), systemZone: tokyo)
        let after = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(12, 1), monotonic: 7360), systemZone: tokyo)
        XCTAssertEqual(after.timeZone, "Asia/Tokyo")
        XCTAssertTrue(after.activeSet.isEmpty)
    }

    func testZoneChangeIsFollowedWhenNothingImpossibleIsActive() {
        for mode in [UnlockMode.basic, .friction] {
            let r = makeReconciler()
            let cfg = config(mode: mode)
            _ = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 0), monotonic: 100), systemZone: vancouver)
            let out = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 2), monotonic: 220), systemZone: tokyo)
            XCTAssertEqual(out.timeZone, "Asia/Tokyo", "\(mode): a softer window does not pin the zone")
        }
        let r = makeReconciler()
        let cfg = config(mode: .impossible)
        _ = r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(13, 0), monotonic: 100), systemZone: vancouver)
        XCTAssertEqual(r.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(13, 2), monotonic: 220), systemZone: tokyo).timeZone, "Asia/Tokyo")
    }

    func testPersistedZoneSurvivesARestartMidWindow() {
        // The daemon restarts (reboot) with the system already in Tokyo; it was reading the
        // schedule in Vancouver, where the Impossible window is still active.
        let cfg = config(mode: .impossible)
        hosts = FakeHosts(base)
        log = FakeLog()
        let restarted = Reconciler(hosts: hosts, dns: FakeDNS(), processes: FakeProcesses(), log: log,
                                   resolver: ConfigResolver(lastGood: cfg), calendar: Calendar(identifier: .gregorian), zone: vancouver)
        let out = restarted.tick(live: cfg, clock: ClockSample(wall: mondayVancouver(10, 0), monotonic: 5), systemZone: tokyo)
        XCTAssertEqual(out.timeZone, "America/Vancouver")
        XCTAssertFalse(out.activeSet.isEmpty)
    }

    func testNoSystemZoneKeepsTheCalendarAsGiven() {
        let r = makeReconciler()
        let out = r.tick(live: config(mode: .basic), clock: ClockSample(wall: mondayVancouver(10, 0), monotonic: 100))
        XCTAssertEqual(out.timeZone, "America/Vancouver")
    }
}
