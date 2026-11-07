import XCTest
@testable import FocusGuardCore

final class LearnedNamesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRecordReportsNewNamesOnly() {
        var learned = LearnedNames()
        XCTAssertTrue(learned.record("mangadex.org", at: t0))
        XCTAssertFalse(learned.record("mangadex.org", at: t0.addingTimeInterval(60)), "already known; last-seen updated")
        XCTAssertEqual(learned.lastSeen["mangadex.org"], t0.addingTimeInterval(60))
        XCTAssertEqual(learned.names, ["mangadex.org"])
    }

    func testRecordNormalizes() {
        var learned = LearnedNames()
        XCTAssertTrue(learned.record("MangaDex.org.", at: t0))
        XCTAssertFalse(learned.record("mangadex.org", at: t0))
    }

    func testEvictionDropsTheOldestBeyondTheCap() {
        var learned = LearnedNames()
        for i in 0..<(LearnedNames.cap + 10) {
            learned.record("site\(i).com", at: t0.addingTimeInterval(Double(i)))
        }
        learned.evictBeyondCap()
        XCTAssertEqual(learned.count, LearnedNames.cap)
        XCTAssertFalse(learned.names.contains("site0.com"), "oldest gone")
        XCTAssertTrue(learned.names.contains("site\(LearnedNames.cap + 9).com"), "newest kept")
    }

    func testBlockedByConfig() {
        let list = BlockList(name: "l", keywords: [KeywordRule(text: "manga", match: .contains)])
        let window = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        let config = Config(blockLists: [list], schedules: [window], alwaysAllow: ["mangalore.in"])
        var learned = LearnedNames()
        for n in ["mangadex.org", "mangalore.in", "comics.org"] { learned.record(n, at: t0) }
        XCTAssertEqual(learned.blocked(by: config, at: LocalMoment(weekday: .mon, minutesSinceMidnight: 600)), ["mangadex.org"])
        XCTAssertEqual(learned.blocked(by: config, at: LocalMoment(weekday: .mon, minutesSinceMidnight: 800)), [])
    }

    func testRoundTripsThroughJSON() throws {
        var learned = LearnedNames()
        learned.record("mangadex.org", at: t0)
        let data = try JSONEncoder().encode(learned)
        XCTAssertEqual(try JSONDecoder().decode(LearnedNames.self, from: data), learned)
    }

    func testRecordRejectsAnythingThatIsNotAHostname() {
        var learned = LearnedNames()
        for bad in ["manga.com\n1.2.3.4 apple.com", "manga.com evil", "manga", "", "a..b", "#manga.com",
                    String(repeating: "a", count: 64) + ".com", "mang\u{E9}.com"] {
            XCTAssertFalse(learned.record(bad, at: t0), bad)
        }
        XCTAssertEqual(learned.count, 0)
        XCTAssertTrue(learned.record("xn--mnga-5qa.com", at: t0), "punycode is fine")
    }

    func testEvictionIsDeterministicOnTies() {
        func run() -> Set<String> {
            var l = LearnedNames()
            for i in 0..<(LearnedNames.cap + 50) { l.record("s\(i).com", at: t0) }
            l.evictBeyondCap()
            return l.names
        }
        XCTAssertEqual(run(), run())
    }
}
