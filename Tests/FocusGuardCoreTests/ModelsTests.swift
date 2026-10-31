import XCTest
@testable import FocusGuardCore

final class ModelsTests: XCTestCase {
    func testTimeOfDayParsesHHmm() {
        XCTAssertEqual(TimeOfDay("09:30"), TimeOfDay(hour: 9, minute: 30))
        XCTAssertEqual(TimeOfDay("09:30")?.minutesSinceMidnight, 570)
        XCTAssertEqual(TimeOfDay(hour: 9, minute: 5)?.string, "09:05")
    }

    func testTimeOfDayRejectsGarbage() {
        XCTAssertNil(TimeOfDay("25:00"))
        XCTAssertNil(TimeOfDay("09:60"))
        XCTAssertNil(TimeOfDay("9"))
        XCTAssertNil(TimeOfDay("nine"))
        XCTAssertNil(TimeOfDay(hour: -1, minute: 0))
    }

    func testTimeOfDayIsComparable() {
        XCTAssertLessThan(TimeOfDay("08:00")!, TimeOfDay("08:01")!)
    }

    func testWeekdayFromCalendarAndPrevious() {
        XCTAssertEqual(Weekday(calendarWeekday: 1), .sun)
        XCTAssertEqual(Weekday(calendarWeekday: 2), .mon)
        XCTAssertEqual(Weekday(calendarWeekday: 7), .sat)
        XCTAssertEqual(Weekday.mon.previous, .sun)
        XCTAssertEqual(Weekday.sun.previous, .sat)
    }

    func testConfigRoundTripsThroughJSON() throws {
        let list = BlockList(name: "Social", domains: ["reddit.com"], appBundleIDs: ["com.tinyspeck.slackmacgap"])
        let window = ScheduleWindow(
            name: "Deep work", days: [.mon, .tue], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!,
            blockListIDs: [list.id], enabled: true)
        let config = Config(blockLists: [list], schedules: [window])

        let data = try config.encodeJSON()
        let decoded = try Config.decodeJSON(data)

        XCTAssertEqual(decoded, config)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"start\" : \"09:00\""), "time encodes as HH:mm string, got:\n\(text)")
    }

    func testDecodeRejectsBadTime() {
        let json = """
        {"version":1,"blockLists":[],"schedules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x","days":["mon"],"start":"99:00","end":"10:00","blockListIDs":[],"enabled":true}]}
        """
        XCTAssertThrowsError(try Config.decodeJSON(Data(json.utf8)))
    }

    func testUnlockModeDefaultsToFrictionWhenAbsent() throws {
        let json = """
        {"version":1,"blockLists":[],"schedules":[{"id":"0B1C2D3E-0000-4000-8000-000000000002",
         "name":"w","days":["mon"],"start":"09:00","end":"10:00","blockListIDs":[],"enabled":true}]}
        """
        let cfg = try Config.decodeJSON(Data(json.utf8))
        XCTAssertEqual(cfg.schedules[0].unlockMode, .friction)
    }

    func testUnlockModeRoundTripsAndOrders() throws {
        var w = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("10:00")!, blockListIDs: [])
        w.unlockMode = .impossible
        let cfg = Config(schedules: [w])
        let decoded = try Config.decodeJSON(try cfg.encodeJSON())
        XCTAssertEqual(decoded.schedules[0].unlockMode, .impossible)
        XCTAssertTrue(String(data: try cfg.encodeJSON(), encoding: .utf8)!.contains("\"unlockMode\" : \"impossible\""))
        XCTAssertLessThan(UnlockMode.basic, UnlockMode.friction)
        XCTAssertLessThan(UnlockMode.friction, UnlockMode.impossible)
        XCTAssertEqual(max(UnlockMode.basic, .impossible), .impossible)
    }
}
