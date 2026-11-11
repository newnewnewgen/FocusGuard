import XCTest
@testable import FocusGuardCore

final class LockChromeTests: XCTestCase {
    let ext = "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*"
    let page = "chrome://extensions/*"
    lazy var list = BlockList(name: "l", domains: ["x.com"], chromeURLs: [ext, page])
    func window(_ lists: [UUID], mode: UnlockMode = .impossible) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: lists, unlockMode: mode)
    }
    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
    let at16 = LocalMoment(weekday: .mon, minutesSinceMidnight: 960)

    func testRemovingAProtectedPatternIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].chromeURLs = [ext]
        XCTAssertEqual(new.weakens(from: old, at: at10), .impossible)
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testEditingAPatternIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id], mode: .friction)])
        var new = old
        new.blockLists[0].chromeURLs[1] = "chrome://settings/*"
        XCTAssertEqual(new.weakens(from: old, at: at10), .friction)
    }

    func testAddingAPatternIsNotACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].chromeURLs.append("chrome://settings/*")
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testMovingAPatternToAnotherAttachedListIsNotACut() {
        let other = BlockList(name: "o")
        let old = Config(blockLists: [list, other], schedules: [window([list.id, other.id])])
        var new = old
        new.blockLists[0].chromeURLs = [ext]
        new.blockLists[1].chromeURLs = [page]
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testBasicWindowReportsBasic() {
        let old = Config(blockLists: [list], schedules: [window([list.id], mode: .basic)])
        var new = old
        new.blockLists[0].chromeURLs = []
        XCTAssertEqual(new.weakens(from: old, at: at10), .basic)
    }
}
