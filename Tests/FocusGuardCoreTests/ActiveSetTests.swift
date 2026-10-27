import XCTest
@testable import FocusGuardCore

final class ActiveSetTests: XCTestCase {
    let social = BlockList(name: "Social", domains: ["Reddit.com", "https://www.youtube.com/"], appBundleIDs: ["com.tinyspeck.slackmacgap"])
    let games = BlockList(name: "Games", domains: ["steampowered.com"], appBundleIDs: ["com.valvesoftware.steam"])
    let mon10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)

    func testUnionOfActiveWindowsLists() {
        let a = ScheduleWindow(name: "a", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [social.id])
        let b = ScheduleWindow(name: "b", days: [.mon], start: TimeOfDay("09:30")!, end: TimeOfDay("10:30")!, blockListIDs: [games.id])
        let cfg = Config(blockLists: [social, games], schedules: [a, b])

        let set = cfg.activeSet(at: mon10)

        XCTAssertEqual(set.domains, ["reddit.com", "youtube.com", "steampowered.com"])
        XCTAssertEqual(set.bundleIDs, ["com.tinyspeck.slackmacgap", "com.valvesoftware.steam"])
    }

    func testInactiveWindowContributesNothing() {
        let a = ScheduleWindow(name: "a", days: [.tue], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [social.id])
        let cfg = Config(blockLists: [social], schedules: [a])
        XCTAssertEqual(cfg.activeSet(at: mon10), .empty)
        XCTAssertTrue(cfg.activeSet(at: mon10).isEmpty)
    }

    func testDanglingBlockListIDIsIgnored() {
        let a = ScheduleWindow(name: "a", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [UUID()])
        let cfg = Config(blockLists: [social], schedules: [a])
        XCTAssertEqual(cfg.activeSet(at: mon10), .empty)
    }

    func testEmptyDomainStringsAreDropped() {
        let junk = BlockList(name: "j", domains: ["  ", "https://"], appBundleIDs: [])
        let a = ScheduleWindow(name: "a", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [junk.id])
        let cfg = Config(blockLists: [junk], schedules: [a])
        XCTAssertEqual(cfg.activeSet(at: mon10).domains, [])
    }

    func testBundleIDsAreTrimmedAndEmptyDropped() {
        let junk = BlockList(name: "j", domains: [], appBundleIDs: ["  com.example.a ", ""])
        let a = ScheduleWindow(name: "a", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [junk.id])
        let cfg = Config(blockLists: [junk], schedules: [a])
        XCTAssertEqual(cfg.activeSet(at: mon10).bundleIDs, ["com.example.a"])
    }
}
