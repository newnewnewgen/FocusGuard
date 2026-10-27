import XCTest
@testable import FocusGuardCore

final class ConfigResolverTests: XCTestCase {
    let list = BlockList(name: "l", domains: ["x.com"], appBundleIDs: [])
    lazy var morning = ScheduleWindow(name: "am", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
    lazy var afternoon = ScheduleWindow(name: "pm", days: [.mon], start: TimeOfDay("12:00")!, end: TimeOfDay("15:00")!, blockListIDs: [list.id])
    lazy var cfg = Config(blockLists: [list], schedules: [morning])
    lazy var backToBack = Config(blockLists: [list], schedules: [morning, afternoon])
    lazy var always = Config(blockLists: [list], schedules: [
        ScheduleWindow(name: "24/7", days: Set(Weekday.allCases), start: TimeOfDay("00:00")!, end: TimeOfDay("23:59")!, blockListIDs: [list.id])])

    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)
    let at1230 = LocalMoment(weekday: .mon, minutesSinceMidnight: 12 * 60 + 30)
    let at16 = LocalMoment(weekday: .mon, minutesSinceMidnight: 16 * 60)

    func testLiveConfigWinsAndBecomesLastGood() {
        var r = ConfigResolver()
        let out = r.resolve(live: cfg, at: at10, monotonic: 0)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .live)
        XCTAssertEqual(r.lastGood, cfg)
    }

    func testNothingAtAllYieldsEmpty() {
        var r = ConfigResolver()
        let out = r.resolve(live: nil, at: at10, monotonic: 0)
        XCTAssertEqual(out.config, .empty)
        XCTAssertEqual(out.source, .none)
    }

    func testVanishMidWindowKeepsEnforcingLastGood() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: at10, monotonic: 0)
        let out = r.resolve(live: nil, at: at10, monotonic: 2)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .lastGood)
    }

    func testReleasedWhenTheVanishTimeWindowEndsAndStaysReleased() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: at10, monotonic: 0)
        _ = r.resolve(live: nil, at: at10, monotonic: 2)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 6 * 3600).source, .none)
        // Next Monday's window must NOT re-arm the fallback.
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 7 * 24 * 3600).source, .none)
    }

    func testBackToBackWindowsDoNotExtendTheFallback() {
        var r = ConfigResolver()
        _ = r.resolve(live: backToBack, at: at10, monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 2).source, .lastGood)
        // 12:30: the afternoon window is active, but it was not the one active when config vanished.
        XCTAssertEqual(r.resolve(live: nil, at: at1230, monotonic: 2.5 * 3600).source, .none)
    }

    func testVanishDuringAfternoonIsBoundedByAfternoon() {
        var r = ConfigResolver()
        _ = r.resolve(live: backToBack, at: at1230, monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at1230, monotonic: 2).source, .lastGood)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 4 * 3600).source, .none)
    }

    func testAlwaysOnScheduleHitsTheAbsoluteCeiling() {
        var r = ConfigResolver(maxFallback: 24 * 3600)
        _ = r.resolve(live: always, at: at10, monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 2).source, .lastGood)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 23 * 3600).source, .lastGood)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 2 + 24 * 3600).source, .none)
    }

    func testLiveConfigReturningReArmsFallback() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: at10, monotonic: 0)
        _ = r.resolve(live: nil, at: at16, monotonic: 1)   // released immediately: nothing active
        _ = r.resolve(live: cfg, at: at10, monotonic: 2)   // live is back
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 3).source, .lastGood)
    }

    func testSeededLastGoodIsUsedOnColdStart() {
        var r = ConfigResolver(lastGood: cfg)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 0).source, .lastGood)
    }
}
