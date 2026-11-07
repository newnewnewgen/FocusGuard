import XCTest
@testable import FocusGuardCore

final class LockKeywordTests: XCTestCase {
    let manga = KeywordRule(text: "manga", match: .contains)
    lazy var list = BlockList(name: "l", domains: ["x.com"], keywords: [manga])
    lazy var plain = BlockList(name: "p", domains: ["y.com"])
    func window(_ lists: [UUID], mode: UnlockMode = .impossible) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: lists, unlockMode: mode)
    }
    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
    let at16 = LocalMoment(weekday: .mon, minutesSinceMidnight: 960)

    func testRemovingAProtectedRuleIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].keywords = []
        XCTAssertEqual(new.weakens(from: old, at: at10), .impossible)
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testChangingTextOrMatchIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var text = old
        text.blockLists[0].keywords[0].text = "mang"
        XCTAssertEqual(text.weakens(from: old, at: at10), .impossible)
        var match = old
        match.blockLists[0].keywords[0].match = .wholeWord
        XCTAssertEqual(match.weakens(from: old, at: at10), .impossible)
    }

    func testAddingARuleIsNotACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].keywords.append(KeywordRule(text: "anime", match: .contains))
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testAddingAnAllowEntryIsACutAtTheKeywordWindowsMode() {
        let old = Config(blockLists: [list, plain], schedules: [window([list.id], mode: .friction), window([plain.id], mode: .impossible)])
        var new = old
        new.alwaysAllow.append("mangalore.in")
        XCTAssertEqual(new.weakens(from: old, at: at10), .friction, "only the window with keyword rules counts")
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testAddingAnAllowEntryWithNoActiveKeywordWindowIsFree() {
        let old = Config(blockLists: [plain], schedules: [window([plain.id])])
        var new = old
        new.alwaysAllow.append("mangalore.in")
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testRemovingAnAllowEntryIsNotACut() {
        var old = Config(blockLists: [list], schedules: [window([list.id])])
        old.alwaysAllow = ["mangalore.in"]
        var new = old
        new.alwaysAllow = []
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testMovingARuleToAnotherAttachedListIsNotACut() {
        let other = BlockList(name: "o")
        let old = Config(blockLists: [list, other], schedules: [window([list.id, other.id])])
        var new = old
        new.blockLists[0].keywords = []
        new.blockLists[1].keywords = [manga]
        XCTAssertNil(new.weakens(from: old, at: at10))
    }
}
