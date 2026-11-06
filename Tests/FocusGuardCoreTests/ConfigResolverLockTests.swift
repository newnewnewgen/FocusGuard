import XCTest
@testable import FocusGuardCore

/// The daemon itself refuses a config that unblocks anything an Impossible window protects, so
/// editing or deleting config.json by hand cannot get around the app's lock.
final class ConfigResolverLockTests: XCTestCase {
    let list = BlockList(name: "l", domains: ["x.com", "y.com"], appBundleIDs: ["com.example.app"])
    lazy var lockedWindow = ScheduleWindow(name: "locked", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!,
                                           blockListIDs: [list.id], unlockMode: .impossible)
    lazy var locked = Config(blockLists: [list], schedules: [lockedWindow])
    lazy var disabled: Config = { var c = locked; c.schedules[0].enabled = false; return c }()

    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)
    let at1230 = LocalMoment(weekday: .mon, minutesSinceMidnight: 12 * 60 + 30)

    private func accepted(_ config: Config, at moment: LocalMoment) -> ConfigResolver {
        var r = ConfigResolver()
        _ = r.resolve(live: config, at: moment, monotonic: 0)
        return r
    }

    func testWeakeningAnImpossibleWindowIsHeld() {
        var r = accepted(locked, at: at10)
        let out = r.resolve(live: disabled, at: at10, monotonic: 2)
        XCTAssertEqual(out.source, .held)
        XCTAssertEqual(out.config, locked, "keeps enforcing what it had accepted")
        XCTAssertEqual(r.lastGood, locked, "the refused config never becomes the accepted one")
    }

    func testHeldChangeIsAcceptedOnceTheWindowEnds() {
        var r = accepted(locked, at: at10)
        _ = r.resolve(live: disabled, at: at10, monotonic: 2)
        let out = r.resolve(live: disabled, at: at1230, monotonic: 9000)
        XCTAssertEqual(out.source, .live)
        XCTAssertEqual(r.lastGood, disabled)
    }

    func testRemovingOneItemIsHeld() {
        var r = accepted(locked, at: at10)
        var fewer = locked
        fewer.blockLists[0].domains = ["x.com"]
        XCTAssertEqual(r.resolve(live: fewer, at: at10, monotonic: 2).source, .held)
    }

    func testEmptyConfigCannotReplaceAnImpossibleWindow() {
        var r = accepted(locked, at: at10)
        XCTAssertEqual(r.resolve(live: .empty, at: at10, monotonic: 2).source, .held)
    }

    func testDeletingThenRecreatingTheFileDoesNotEscape() {
        var r = accepted(locked, at: at10)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 2).source, .lastGood)
        XCTAssertEqual(r.resolve(live: .empty, at: at10, monotonic: 4).source, .held)
        XCTAssertEqual(r.lastGood, locked)
    }

    func testStrengtheningDuringAnImpossibleWindowIsAccepted() {
        var r = accepted(locked, at: at10)
        var more = locked
        more.blockLists[0].domains.append("z.com")
        more.schedules[0].end = TimeOfDay("13:00")!
        let out = r.resolve(live: more, at: at10, monotonic: 2)
        XCTAssertEqual(out.source, .live)
        XCTAssertEqual(r.lastGood, more)
    }

    func testFrictionAndBasicWindowsAreNotHeldByTheDaemon() {
        for mode in [UnlockMode.basic, .friction] {
            var softer = locked
            softer.schedules[0].unlockMode = mode
            var r = accepted(softer, at: at10)
            var off = softer
            off.schedules[0].enabled = false
            XCTAssertEqual(r.resolve(live: off, at: at10, monotonic: 2).source, .live, "\(mode)")
        }
    }

    func testChangesOutsideTheWindowAreAccepted() {
        var r = accepted(locked, at: at1230)
        XCTAssertEqual(r.resolve(live: disabled, at: at1230, monotonic: 2).source, .live)
    }

    func testHeldSurvivesADaemonRestart() {
        let first = accepted(locked, at: at10)
        var restarted = ConfigResolver(lastGood: first.lastGood)
        XCTAssertEqual(restarted.resolve(live: disabled, at: at10, monotonic: 0).source, .held)
    }

    func testRestoringTheAcceptedConfigClearsTheHold() {
        var r = accepted(locked, at: at10)
        _ = r.resolve(live: disabled, at: at10, monotonic: 2)
        XCTAssertEqual(r.resolve(live: locked, at: at10, monotonic: 4).source, .live)
    }

    func testDeletingTheFileDoesNotOutlastAnAllDayImpossibleWindow() {
        var allDay = locked
        allDay.schedules[0].days = Set(Weekday.allCases)
        allDay.schedules[0].start = TimeOfDay("00:00")!
        allDay.schedules[0].end = TimeOfDay("23:59")!
        var r = ConfigResolver(maxFallback: 24 * 3600)
        _ = r.resolve(live: allDay, at: at10, monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 2).source, .lastGood)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 30 * 3600).source, .lastGood,
                       "the 24 h ceiling is for softer windows only")
    }

    func testFirstConfigEverIsAccepted() {
        var r = ConfigResolver()
        XCTAssertEqual(r.resolve(live: locked, at: at10, monotonic: 0).source, .live)
    }
}
