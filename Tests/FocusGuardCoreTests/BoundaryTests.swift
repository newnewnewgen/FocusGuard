import XCTest
@testable import FocusGuardCore

final class BoundaryTests: XCTestCase {
    // A fixed calendar so tests do not depend on the machine's zone.
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }()

    /// 2026-10-26 is a Monday.
    func date(_ day: Int, _ h: Int, _ m: Int, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
    }

    let list = BlockList(name: "L", domains: ["a.com"])

    func window(_ days: Set<Weekday>, _ s: String, _ e: String, enabled: Bool = true) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: days, start: TimeOfDay(s)!, end: TimeOfDay(e)!, blockListIDs: [list.id], enabled: enabled)
    }

    func testNextBoundaryIsStartThenEndSameDay() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "09:00", "12:00")])
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 8, 0), calendar: cal), date(26, 9, 0))
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 9, 0), calendar: cal), date(26, 12, 0))
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 10, 30), calendar: cal), date(26, 12, 0))
    }

    func testNextBoundaryWrapsToNextWeek() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "09:00", "12:00")])
        // Monday 13:00 → next Monday 09:00 (Nov 2).
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 13, 0), calendar: cal), date(2, 9, 0, month: 11))
    }

    func testMidnightCrossingWindowEndsOnFollowingDay() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "22:00", "02:00")])
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 23, 0), calendar: cal), date(27, 2, 0))
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 21, 0), calendar: cal), date(26, 22, 0))
    }

    func testDisabledEmptyAndDegenerateWindowsAreIgnored() {
        let cfg = Config(blockLists: [list], schedules: [
            window([.mon], "09:00", "12:00", enabled: false),
            window([.mon], "10:00", "10:00"),
        ])
        XCTAssertNil(cfg.nextBoundary(after: date(26, 8, 0), calendar: cal))
        XCTAssertNil(Config.empty.nextBoundary(after: date(26, 8, 0), calendar: cal))
    }

    func testEarliestAcrossWindowsWins() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "09:00", "12:00"), window([.mon], "08:30", "08:45")])
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 8, 0), calendar: cal), date(26, 8, 30))
    }

    func testDSTFallBackDayStillFindsBoundary() {
        // Nov 1 2026 is the fall-back Sunday in Vancouver.
        let cfg = Config(blockLists: [list], schedules: [window([.sun], "09:00", "12:00")])
        XCTAssertEqual(cfg.nextBoundary(after: date(1, 0, 30, month: 11), calendar: cal), date(1, 9, 0, month: 11))
    }

    func testWindowsStartingAtMoment() {
        let a = window([.mon], "09:00", "12:00")
        let b = window([.mon], "09:00", "10:00")
        let c = window([.tue], "09:00", "10:00")
        let cfg = Config(blockLists: [list], schedules: [a, b, c])
        XCTAssertEqual(cfg.windows(startingAt: LocalMoment(weekday: .mon, minutesSinceMidnight: 540)).map(\.id), [a.id, b.id])
        XCTAssertTrue(cfg.windows(startingAt: LocalMoment(weekday: .mon, minutesSinceMidnight: 541)).isEmpty)
    }
}
