import XCTest
@testable import FocusGuardCore

final class LockTests: XCTestCase {
    let social = BlockList(name: "Social", domains: ["reddit.com"], appBundleIDs: ["com.slack"])
    let games = BlockList(name: "Games", domains: ["steampowered.com"])
    let mon10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)

    func w(_ name: String, _ s: String, _ e: String, lists: [BlockList], mode: UnlockMode, days: Set<Weekday> = [.mon]) -> ScheduleWindow {
        ScheduleWindow(name: name, days: days, start: TimeOfDay(s)!, end: TimeOfDay(e)!, blockListIDs: lists.map(\.id), unlockMode: mode)
    }

    // MARK: lockState

    func testIdleConfigHasNoLocks() {
        let cfg = Config(blockLists: [social], schedules: [w("a", "11:00", "12:00", lists: [social], mode: .impossible)])
        let s = cfg.lockState(at: mon10)
        XCTAssertEqual(s, LockState())
        XCTAssertNil(s.lockedUntil)
    }

    func testActiveWindowLocksItsListsWithStrictestMode() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .friction)
        let b = w("b", "09:30", "10:30", lists: [social, games], mode: .impossible)
        let cfg = Config(blockLists: [social, games], schedules: [a, b])
        let s = cfg.lockState(at: mon10)
        XCTAssertEqual(s.windowModes, [a.id: .friction, b.id: .impossible])
        XCTAssertEqual(s.listModes, [social.id: .impossible, games.id: .impossible])
        XCTAssertEqual(s.overall, .impossible)
        XCTAssertEqual(s.lockedUntil, TimeOfDay("12:00")!)
    }

    func testLockedUntilSpansBackToBackWindowsAndMidnight() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .basic)
        let b = w("b", "12:00", "01:00", lists: [games], mode: .basic)
        let cfg = Config(blockLists: [social, games], schedules: [a, b])
        XCTAssertEqual(cfg.lockState(at: mon10).lockedUntil, TimeOfDay("01:00")!)
    }

    func testTwentyFourSevenWindowLocksForAtMostADay() {
        let a = w("a", "00:00", "23:59", lists: [social], mode: .basic, days: Set(Weekday.allCases))
        let cfg = Config(blockLists: [social], schedules: [a])
        // Only the one-minute gap at 23:59 ends it.
        XCTAssertEqual(cfg.lockState(at: mon10).lockedUntil, TimeOfDay("23:59")!)
    }

    // MARK: weakens

    func testNoChangeOrAdditionNeverWeakens() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.blockLists[0].domains.append("youtube.com")
        new.schedules.append(w("b", "13:00", "14:00", lists: [social], mode: .basic))
        XCTAssertNil(old.weakens(from: old, at: mon10))
        XCTAssertNil(new.weakens(from: old, at: mon10))
    }

    func testRemovingActiveItemWeakensWithWindowMode() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .friction)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.blockLists[0].domains = []
        XCTAssertEqual(new.weakens(from: old, at: mon10), .friction)
        var new2 = old
        new2.blockLists[0].appBundleIDs = []
        XCTAssertEqual(new2.weakens(from: old, at: mon10), .friction)
    }

    func testRemovalCoveredByAnotherActiveListDoesNotWeaken() {
        let dup = BlockList(name: "Dup", domains: ["reddit.com"], appBundleIDs: ["com.slack"])
        let a = w("a", "09:00", "12:00", lists: [social, dup], mode: .impossible)
        let old = Config(blockLists: [social, dup], schedules: [a])
        var new = old
        new.blockLists.removeAll { $0.id == dup.id }
        new.schedules[0].blockListIDs = [social.id]
        XCTAssertNil(new.weakens(from: old, at: mon10))
    }

    func testShorteningEndWeakensExtendingDoesNot() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var shorter = old
        shorter.schedules[0].end = TimeOfDay("11:00")!
        XCTAssertEqual(shorter.weakens(from: old, at: mon10), .impossible)
        var longer = old
        longer.schedules[0].end = TimeOfDay("13:00")!
        XCTAssertNil(longer.weakens(from: old, at: mon10))
    }

    func testDisablingDeletingOrRemovingTodayWeakens() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .basic)
        let old = Config(blockLists: [social], schedules: [a])
        var disabled = old; disabled.schedules[0].enabled = false
        XCTAssertEqual(disabled.weakens(from: old, at: mon10), .basic)
        var deleted = old; deleted.schedules = []
        XCTAssertEqual(deleted.weakens(from: old, at: mon10), .basic)
        var noMonday = old; noMonday.schedules[0].days = [.tue]
        XCTAssertEqual(noMonday.weakens(from: old, at: mon10), .basic)
    }

    func testLoweringModeOfActiveWindowWeakensAtOldMode() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.schedules[0].unlockMode = .basic
        XCTAssertEqual(new.weakens(from: old, at: mon10), .impossible)
        var raised = old
        raised.schedules[0].unlockMode = .impossible
        XCTAssertNil(raised.weakens(from: old, at: mon10))
    }

    func testFutureCutWithinActiveStretchIsCaught() {
        // Edit does not change the active set *now* but removes coverage at 11:00, still inside the window.
        let a = w("a", "09:00", "11:00", lists: [social], mode: .friction)
        let b = w("b", "11:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a, b])
        var new = old
        new.schedules.removeAll { $0.id == b.id }
        XCTAssertEqual(new.weakens(from: old, at: mon10), .impossible)
    }

    func testEditsOutsideAnyActiveWindowAreFree() {
        let a = w("a", "11:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.schedules = []
        XCTAssertNil(new.weakens(from: old, at: mon10))
    }
}
