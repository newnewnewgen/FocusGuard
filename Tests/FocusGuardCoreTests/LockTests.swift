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

    func testAllDayWindowReleasesAtItsOneMinuteGap() {
        let a = w("a", "00:00", "23:59", lists: [social], mode: .basic, days: Set(Weekday.allCases))
        let cfg = Config(blockLists: [social], schedules: [a])
        // Only the one-minute gap at 23:59 ends it.
        XCTAssertEqual(cfg.lockState(at: mon10).lockedUntil, TimeOfDay("23:59")!)
    }

    func testGaplessScheduleHasOverallButNoLockedUntil() {
        let all = Set(Weekday.allCases)
        let am = w("am", "00:00", "12:00", lists: [social], mode: .basic, days: all)
        let pm = w("pm", "12:00", "00:00", lists: [games], mode: .friction, days: all)
        let s = Config(blockLists: [social, games], schedules: [am, pm]).lockState(at: mon10)
        XCTAssertEqual(s.overall, .basic)
        XCTAssertNil(s.lockedUntil, "no idle minute within 24 h")
    }

    func testLockStateIgnoresDanglingListIDs() {
        var a = w("a", "09:00", "12:00", lists: [social], mode: .friction)
        a.blockListIDs.append(UUID())
        let s = Config(blockLists: [social], schedules: [a]).lockState(at: mon10)
        XCTAssertEqual(s.listModes, [social.id: .friction])
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

    // MARK: weakens — item-level effective protection

    func testDisablingImpossibleWindowStillCoveredByBasicWindowWeakensAtImpossible() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let b = w("b", "09:00", "12:00", lists: [social], mode: .basic)
        let old = Config(blockLists: [social], schedules: [a, b])
        var disabled = old; disabled.schedules[0].enabled = false
        XCTAssertEqual(disabled.weakens(from: old, at: mon10), .impossible)
        var noMonday = old; noMonday.schedules[0].days = [.tue]
        XCTAssertEqual(noMonday.weakens(from: old, at: mon10), .impossible)
    }

    func testReplacingImpossibleWindowWithNewIDBasicWindowWeakens() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        let replacement = w("a2", "09:00", "12:00", lists: [social], mode: .basic)
        let new = Config(blockLists: [social], schedules: [replacement])
        XCTAssertEqual(new.weakens(from: old, at: mon10), .impossible)
    }

    func testDeletingBasicWindowWhoseItemsStayCoveredDoesNotWeaken() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .basic)
        let b = w("b", "09:00", "12:00", lists: [social], mode: .friction)
        let old = Config(blockLists: [social], schedules: [a, b])
        var new = old
        new.schedules.removeAll { $0.id == a.id }
        XCTAssertNil(new.weakens(from: old, at: mon10))
    }

    func testShorteningMidnightCrossingWindowWeakens() {
        let a = w("a", "22:00", "02:00", lists: [social], mode: .friction)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.schedules[0].end = TimeOfDay("01:00")!
        let mon23 = LocalMoment(weekday: .mon, minutesSinceMidnight: 23 * 60)
        XCTAssertEqual(new.weakens(from: old, at: mon23), .friction)
    }

    func testLoweringModeOfLaterBackToBackWindowWeakensAtItsOldMode() {
        let a = w("a", "09:00", "11:00", lists: [social], mode: .basic)
        let b = w("b", "11:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a, b])
        var new = old
        new.schedules[1].unlockMode = .friction
        XCTAssertEqual(new.weakens(from: old, at: mon10), .impossible)
    }

    // MARK: performance

    func testWeakensAndLockStateAreFastOnLargeAllDayConfig() {
        let lists = (0..<4).map { i in
            BlockList(name: "L\(i)",
                      domains: (0..<100).map { "site\(i)-\($0).example.com" },
                      appBundleIDs: (0..<20).map { "com.example.app\(i).\($0)" })
        }
        let all = Set(Weekday.allCases)
        let old = Config(blockLists: lists, schedules: [
            w("a", "00:00", "23:59", lists: [lists[0], lists[1]], mode: .basic, days: all),
            w("b", "00:00", "23:59", lists: [lists[1], lists[2]], mode: .friction, days: all),
            w("c", "00:00", "23:59", lists: [lists[2], lists[3]], mode: .impossible, days: all),
            w("d", "00:00", "23:59", lists: lists, mode: .basic, days: all),
        ])
        var new = old
        new.blockLists[0].domains.removeFirst()   // list 0's effective protection is .basic
        var new1 = old
        new1.blockLists[1].domains.removeFirst()  // list 1 is covered by b at .friction

        XCTAssertEqual(new.weakens(from: old, at: mon10), .basic)
        let elapsed = Self.bestCPUSeconds { _ = new.weakens(from: old, at: self.mon10) }
        XCTAssertLessThan(elapsed, 0.05, "weakens took \(elapsed) s")
        XCTAssertEqual(new1.weakens(from: old, at: mon10), .friction)

        let s = old.lockState(at: mon10)
        let elapsed2 = Self.bestCPUSeconds { _ = old.lockState(at: self.mon10) }
        XCTAssertLessThan(elapsed2, 0.05, "lockState took \(elapsed2) s")
        XCTAssertEqual(s.overall, .impossible)
        XCTAssertEqual(s.lockedUntil, TimeOfDay("23:59")!)
    }

    /// Fastest of `runs` executions, in CPU seconds of this thread. Wall time (`Date()`) on a single
    /// run also counts time spent preempted, which made this test fail on a busy machine.
    private static func bestCPUSeconds(runs: Int = 5, _ body: () -> Void) -> Double {
        (0..<runs).map { _ in
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            body()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        }.min()!
    }
}
