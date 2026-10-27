import XCTest
@testable import FocusGuardCore

final class ConfigResolverTests: XCTestCase {
    let list = BlockList(name: "l", domains: ["x.com"], appBundleIDs: [])
    lazy var cfg = Config(
        blockLists: [list],
        schedules: [ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])])
    let inside = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)
    let outside = LocalMoment(weekday: .mon, minutesSinceMidnight: 13 * 60)

    func testLiveConfigWinsAndBecomesLastGood() {
        var r = ConfigResolver()
        let out = r.resolve(live: cfg, at: inside)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .live)
        XCTAssertEqual(r.lastGood, cfg)
    }

    func testNothingAtAllYieldsEmpty() {
        var r = ConfigResolver()
        let out = r.resolve(live: nil, at: inside)
        XCTAssertEqual(out.config, .empty)
        XCTAssertEqual(out.source, .none)
    }

    func testVanishMidWindowKeepsEnforcingLastGood() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: inside)
        let out = r.resolve(live: nil, at: inside)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .lastGood)
    }

    func testFallbackIsReleasedOnceNoWindowIsActiveAndStaysReleased() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: inside)
        _ = r.resolve(live: nil, at: inside)
        XCTAssertEqual(r.resolve(live: nil, at: outside).source, .none)
        // A later window must NOT re-arm the fallback: that would be an unbounded lockout.
        XCTAssertEqual(r.resolve(live: nil, at: inside).source, .none)
    }

    func testLiveConfigReturningReArmsFallback() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: inside)
        _ = r.resolve(live: nil, at: outside)   // released
        _ = r.resolve(live: cfg, at: inside)    // live is back
        XCTAssertEqual(r.resolve(live: nil, at: inside).source, .lastGood)
    }

    func testSeededLastGoodIsUsedOnColdStart() {
        var r = ConfigResolver(lastGood: cfg)
        XCTAssertEqual(r.resolve(live: nil, at: inside).source, .lastGood)
    }
}
