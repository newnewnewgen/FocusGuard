import XCTest
@testable import FocusGuardCore

final class ScheduleTests: XCTestCase {
    private func window(days: Set<Weekday>, _ start: String, _ end: String, enabled: Bool = true) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: days, start: TimeOfDay(start)!, end: TimeOfDay(end)!, blockListIDs: [], enabled: enabled)
    }
    private func at(_ day: Weekday, _ hhmm: String) -> LocalMoment {
        LocalMoment(weekday: day, minutesSinceMidnight: TimeOfDay(hhmm)!.minutesSinceMidnight)
    }

    func testInsideWindowOnListedDay() {
        let w = window(days: [.mon], "09:00", "12:00")
        XCTAssertTrue(w.isActive(at: at(.mon, "09:00")))
        XCTAssertTrue(w.isActive(at: at(.mon, "11:59")))
    }

    func testEndIsExclusive() {
        let w = window(days: [.mon], "09:00", "12:00")
        XCTAssertFalse(w.isActive(at: at(.mon, "12:00")))
    }

    func testOutsideHoursOrWrongDay() {
        let w = window(days: [.mon], "09:00", "12:00")
        XCTAssertFalse(w.isActive(at: at(.mon, "08:59")))
        XCTAssertFalse(w.isActive(at: at(.tue, "10:00")))
    }

    func testDisabledNeverActive() {
        let w = window(days: [.mon], "09:00", "12:00", enabled: false)
        XCTAssertFalse(w.isActive(at: at(.mon, "10:00")))
    }

    func testCrossesMidnightBelongsToStartDay() {
        // Friday 22:00 → 02:00 means Fri night into Sat morning.
        let w = window(days: [.fri], "22:00", "02:00")
        XCTAssertTrue(w.isActive(at: at(.fri, "23:30")))
        XCTAssertTrue(w.isActive(at: at(.sat, "01:59")))
        XCTAssertFalse(w.isActive(at: at(.sat, "02:00")))
        XCTAssertFalse(w.isActive(at: at(.sat, "23:30")), "Saturday night is not listed")
        XCTAssertFalse(w.isActive(at: at(.fri, "01:00")), "Friday early morning is Thursday's night")
    }

    func testZeroLengthWindowNeverActive() {
        let w = window(days: [.mon], "09:00", "09:00")
        XCTAssertFalse(w.isActive(at: at(.mon, "09:00")))
    }

    func testLocalMomentFromDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Vancouver")!
        // 2026-10-27 is a Tuesday.
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14, minute: 7))!
        let m = LocalMoment(date: date, calendar: cal)
        XCTAssertEqual(m, LocalMoment(weekday: .tue, minutesSinceMidnight: 14 * 60 + 7))
    }

    func testWeekdayNext() {
        XCTAssertEqual(Weekday.mon.next, .tue)
        XCTAssertEqual(Weekday.sun.next, .mon)
    }

    func testLocalMomentAdvancesAcrossMidnight() {
        let m = LocalMoment(weekday: .mon, minutesSinceMidnight: 23 * 60 + 50)
        XCTAssertEqual(m.advanced(byMinutes: 5), LocalMoment(weekday: .mon, minutesSinceMidnight: 23 * 60 + 55))
        XCTAssertEqual(m.advanced(byMinutes: 10), LocalMoment(weekday: .tue, minutesSinceMidnight: 0))
        XCTAssertEqual(m.advanced(byMinutes: 10 + 1440), LocalMoment(weekday: .wed, minutesSinceMidnight: 0))
        XCTAssertEqual(m.timeOfDay, TimeOfDay("23:50")!)
    }
}
