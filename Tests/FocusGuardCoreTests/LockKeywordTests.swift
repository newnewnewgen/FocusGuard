import XCTest
@testable import FocusGuardCore

final class LockKeywordTests: XCTestCase {
    let manga = KeywordRule(text: "manga", match: .contains)
    lazy var list = BlockList(name: "l", domains: ["x.com"], keywords: [manga])
    lazy var plain = BlockList(name: "p", domains: ["y.com"])
    func window(_ lists: [UUID], _ s: String = "09:00", _ e: String = "12:00") -> ScheduleWindow {
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay(s)!, end: TimeOfDay(e)!, blockListIDs: lists)
    }
    func cfg(_ lists: [BlockList], _ windows: [ScheduleWindow], mode: UnlockMode = .impossible) -> Config {
        Config(blockLists: lists, schedules: windows, unlockMode: mode)
    }
    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
    let at16 = LocalMoment(weekday: .mon, minutesSinceMidnight: 960)

    func testRemovingAProtectedRuleIsACut() {
        let old = cfg([list], [window([list.id])])
        var new = old
        new.blockLists[0].keywords = []
        XCTAssertEqual(new.weakens(from: old, at: at10), .impossible)
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testChangingTextOrMatchIsACut() {
        let old = cfg([list], [window([list.id])])
        var text = old
        text.blockLists[0].keywords[0].text = "mang"
        XCTAssertEqual(text.weakens(from: old, at: at10), .impossible)
        var match = old
        match.blockLists[0].keywords[0].match = .wholeWord
        XCTAssertEqual(match.weakens(from: old, at: at10), .impossible)
    }

    func testAddingARuleIsNotACut() {
        let old = cfg([list], [window([list.id])])
        var new = old
        new.blockLists[0].keywords.append(KeywordRule(text: "anime", match: .contains))
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testAddingAnAllowEntryIsACutAtTheAppMode() {
        let old = cfg([list, plain], [window([list.id]), window([plain.id])], mode: .friction)
        var new = old
        new.alwaysAllow.append("mangalore.in")
        XCTAssertEqual(new.weakens(from: old, at: at10), .friction)
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testAddingAnAllowEntryWithNoActiveKeywordWindowIsFree() {
        let old = cfg([plain], [window([plain.id])])
        var new = old
        new.alwaysAllow.append("mangalore.in")
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testRemovingAnAllowEntryIsNotACut() {
        var old = cfg([list], [window([list.id])])
        old.alwaysAllow = ["mangalore.in"]
        var new = old
        new.alwaysAllow = []
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testMovingARuleToAnotherAttachedListIsNotACut() {
        let other = BlockList(name: "o")
        let old = cfg([list, other], [window([list.id, other.id])])
        var new = old
        new.blockLists[0].keywords = []
        new.blockLists[1].keywords = [manga]
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testMovingAProtectedRuleToAListOfAnotherWindowIsJudgedByThatWindowsCoverage() {
        let other = BlockList(name: "o")
        // The other list's window is active too: the rule stays protected.
        let covered = cfg([list, other], [window([list.id]), window([other.id])])
        var moved = covered
        moved.blockLists[0].keywords = []
        moved.blockLists[1].keywords = [manga]
        XCTAssertNil(moved.weakens(from: covered, at: at10))
        // The other list's window is not active now: the rule is unprotected until 13:00.
        let later = cfg([list, other], [window([list.id]), window([other.id], "13:00", "14:00")])
        var uncovered = later
        uncovered.blockLists[0].keywords = []
        uncovered.blockLists[1].keywords = [manga]
        XCTAssertEqual(uncovered.weakens(from: later, at: at10), .impossible)
    }

    func testAllowEntryIsJudgedAtALaterKeywordWindowInTheSameStretch() {
        let early = ScheduleWindow(name: "e", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("11:00")!, blockListIDs: [plain.id])
        let late = ScheduleWindow(name: "l", days: [.mon], start: TimeOfDay("10:30")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        let old = cfg([list, plain], [early, late], mode: .friction)
        var new = old
        new.alwaysAllow.append("mangalore.in")
        XCTAssertEqual(new.weakens(from: old, at: at10), .friction)
    }
}
