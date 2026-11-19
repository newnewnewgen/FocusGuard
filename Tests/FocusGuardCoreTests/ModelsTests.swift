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

    // MARK: unlockMode — app-wide (0.7) and migration from per-window (0.6)

    private func window(_ id: String, mode: String?, enabled: Bool? = nil) -> String {
        var fields = ["\"id\":\"0B1C2D3E-0000-4000-8000-\(id)\"", "\"name\":\"w\"", "\"days\":[\"mon\"]",
                      "\"start\":\"09:00\"", "\"end\":\"10:00\"", "\"blockListIDs\":[]"]
        fields.append("\"enabled\":\(enabled ?? true)")
        if let mode { fields.append("\"unlockMode\":\"\(mode)\"") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func decode(windows: [String], topLevel: String? = nil) throws -> Config {
        let mode = topLevel.map { ",\"unlockMode\":\"\($0)\"" } ?? ""
        let json = "{\"version\":1,\"blockLists\":[],\"schedules\":[\(windows.joined(separator: ","))]\(mode)}"
        return try Config.decodeJSON(Data(json.utf8))
    }

    func testMissingUnlockModeMigratesToTheStrictestEnabledWindowMode() throws {
        let cfg = try decode(windows: [window("000000000001", mode: "impossible"), window("000000000002", mode: "friction")])
        XCTAssertEqual(cfg.unlockMode, .impossible)
    }

    func testMigrationIgnoresDisabledWindows() throws {
        let cfg = try decode(windows: [window("000000000001", mode: "impossible", enabled: false),
                                       window("000000000002", mode: "friction")])
        XCTAssertEqual(cfg.unlockMode, .friction)
    }

    func testMigrationWithNoWindowModesIsBasic() throws {
        XCTAssertEqual(try decode(windows: [window("000000000001", mode: nil)]).unlockMode, .basic)
        XCTAssertEqual(try decode(windows: []).unlockMode, .basic)
    }

    func testTopLevelUnlockModeWinsOverWindowValues() throws {
        let cfg = try decode(windows: [window("000000000001", mode: "impossible")], topLevel: "basic")
        XCTAssertEqual(cfg.unlockMode, .basic)
    }

    func testUnlockModeRoundTripsAndOrders() throws {
        let w = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("10:00")!, blockListIDs: [])
        for mode in UnlockMode.allCases {
            let cfg = Config(schedules: [w], unlockMode: mode)
            let data = try cfg.encodeJSON()
            let decoded = try Config.decodeJSON(data)
            XCTAssertEqual(decoded.unlockMode, mode)
            XCTAssertEqual(decoded, cfg)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"unlockMode\" : \"\(mode.rawValue)\""),
                          "encoded as a top-level key")
        }
        XCTAssertLessThan(UnlockMode.basic, UnlockMode.friction)
        XCTAssertLessThan(UnlockMode.friction, UnlockMode.impossible)
        XCTAssertEqual(max(UnlockMode.basic, .impossible), .impossible)
    }
}
