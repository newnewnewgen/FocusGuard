import XCTest
@testable import FocusGuardCore

final class KeywordMatcherTests: XCTestCase {
    func testActiveSetWithLearnedNamesStaysCheapAtTheLimits() {
        var lists: [BlockList] = []
        var windows: [ScheduleWindow] = []
        for i in 0..<Config.Limits.maxWindows {
            let rules = (0..<4).map { KeywordRule(text: "kw\(i)x\($0)", match: .contains) }
            let l = BlockList(name: "l\(i)", keywords: rules)
            lists.append(l)
            windows.append(ScheduleWindow(name: "w\(i)", days: [.mon], start: TimeOfDay("00:00")!, end: TimeOfDay("23:00")!, blockListIDs: [l.id]))
        }
        lists[0].keywords += (0..<(Config.Limits.maxKeywords - 4 * 48)).map { KeywordRule(text: "extra\($0)", match: .contains) }
        var config = Config(blockLists: lists, schedules: windows)
        config.alwaysAllow = (0..<Config.Limits.maxAllow).map { "allowed\($0).example.com" }
        let learned = Set((0..<2000).map { "site\($0)-kw3x1.example.org" })
        let moment = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
        var count = 0
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        count = config.activeSet(at: moment, learned: learned).domains.count
        let seconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        XCTAssertEqual(count, 2000)
        XCTAssertLessThan(seconds, 0.5)
    }
}
