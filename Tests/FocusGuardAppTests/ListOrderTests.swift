import XCTest
import FocusGuardCore
@testable import FocusGuard

final class ListOrderTests: XCTestCase {
    private let a = BlockList(name: "a", domains: ["a.com"])
    private let b = BlockList(name: "b", domains: ["b.com"])

    func testNewWindowAttachesOnlyTheDefaultList() {
        let w = Config(blockLists: [a, b]).newWindow()
        XCTAssertEqual(w.blockListIDs, [a.id], "the first list is the default; the second is not attached")
        XCTAssertEqual(w.days, [.mon, .tue, .wed, .thu, .fri])
        XCTAssertEqual(w.start, TimeOfDay("09:00")!)
        XCTAssertEqual(w.end, TimeOfDay("12:00")!)
        XCTAssertTrue(w.enabled)
    }

    func testNewWindowWithNoListsAttachesNothing() {
        XCTAssertEqual(Config.empty.newWindow().blockListIDs, [])
    }

    func testMovingListsChangesTheirOrderAndNothingElse() {
        let w = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!,
                               blockListIDs: [a.id, b.id], unlockMode: .impossible)
        let before = Config(blockLists: [a, b], schedules: [w], alwaysAllow: ["x.com"])
        var after = before
        after.moveLists(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(after.blockLists.map(\.id), [b.id, a.id])
        XCTAssertEqual(after.schedules, before.schedules)
        XCTAssertEqual(after.alwaysAllow, before.alwaysAllow)
        XCTAssertEqual(after.newWindow().blockListIDs, [b.id], "the default follows the order")
    }

    func testReorderingNeverWeakens() {
        // An Impossible window is active and covers both lists; moving them is still not a cut.
        let w = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!,
                               blockListIDs: [a.id, b.id], unlockMode: .impossible)
        let before = Config(blockLists: [a, b], schedules: [w])
        var after = before
        after.moveLists(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let inside = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
        XCTAssertNotNil(before.lockState(at: inside).overall, "precondition: the window is active")
        XCTAssertNil(after.weakens(from: before, at: inside))
    }
}
