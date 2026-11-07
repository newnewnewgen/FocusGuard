import XCTest
@testable import FocusGuardCore

final class LearnedNamesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRecordReportsNewNamesOnly() {
        var learned = LearnedNames()
        XCTAssertTrue(learned.record("mangadex.org", at: t0))
        XCTAssertFalse(learned.record("mangadex.org", at: t0.addingTimeInterval(7200)), "already known; last-seen updated")
        XCTAssertEqual(learned.lastSeen["mangadex.org"], t0.addingTimeInterval(7200))
        XCTAssertEqual(learned.names, ["mangadex.org"])
    }

    func testRecordNormalizes() {
        var learned = LearnedNames()
        XCTAssertTrue(learned.record("MangaDex.org.", at: t0))
        XCTAssertFalse(learned.record("mangadex.org", at: t0))
    }

    func testEvictionDropsTheOldestBeyondTheCap() {
        var learned = LearnedNames()
        learned = LearnedNames(lastSeen: Dictionary(uniqueKeysWithValues:
            (0..<(LearnedNames.cap + 10)).map { ("site\($0).com", t0.addingTimeInterval(Double($0))) }))
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

    func testRecordAtTheCapDropsTheOldestFivePercent() {
        var learned = LearnedNames()
        for i in 0..<LearnedNames.cap { learned.record("site\(i).com", at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(learned.count, LearnedNames.cap)
        XCTAssertTrue(learned.record("extra.com", at: t0.addingTimeInterval(1e6)))
        XCTAssertEqual(learned.count, LearnedNames.cap - LearnedNames.cap / 20 + 1)
        XCTAssertFalse(learned.names.contains("site0.com"))
        XCTAssertFalse(learned.names.contains("site\(LearnedNames.cap / 20 - 1).com"))
        XCTAssertTrue(learned.names.contains("site\(LearnedNames.cap / 20).com"))
        XCTAssertTrue(learned.names.contains("extra.com"))
    }

    func testRepeatRecordOnlyRefreshesAfterAnHour() {
        var learned = LearnedNames()
        learned.record("mangadex.org", at: t0)
        learned.record("mangadex.org", at: t0.addingTimeInterval(3000))
        XCTAssertEqual(learned.lastSeen["mangadex.org"], t0)
        learned.record("mangadex.org", at: t0.addingTimeInterval(3601))
        XCTAssertEqual(learned.lastSeen["mangadex.org"], t0.addingTimeInterval(3601))
    }

    func testEvictionIsDeterministicOnTies() {
        func run() -> Set<String> {
            var l = LearnedNames(lastSeen: Dictionary(uniqueKeysWithValues:
                (0..<(LearnedNames.cap + 50)).map { ("s\($0).com", t0) }))
            l.evictBeyondCap()
            return l.names
        }
        XCTAssertEqual(run(), run())
    }

    // MARK: Protected names (F3): a name in /etc/hosts never produces a lookup, so its lastSeen
    // freezes; eviction must not pick exactly the names being enforced.

    func testRecordAtTheCapEvictsUnprotectedNamesFirst() {
        var learned = LearnedNames()
        for i in 0..<LearnedNames.cap { learned.record("site\(i).com", at: t0.addingTimeInterval(Double(i))) }
        let protected: Set<String> = Set((0..<200).map { "site\($0).com" })  // the 200 oldest are being enforced
        XCTAssertTrue(learned.record("extra.com", at: t0.addingTimeInterval(1e6), protected: protected))
        XCTAssertEqual(learned.count, LearnedNames.cap - LearnedNames.cap / 20 + 1)
        for p in protected { XCTAssertTrue(learned.names.contains(p), "\(p) is enforced and must survive") }
        XCTAssertFalse(learned.names.contains("site200.com"), "oldest unprotected gone")
        XCTAssertFalse(learned.names.contains("site\(200 + LearnedNames.cap / 20 - 1).com"))
        XCTAssertTrue(learned.names.contains("site\(200 + LearnedNames.cap / 20).com"))
        XCTAssertTrue(learned.names.contains("extra.com"))
    }

    func testRecordAtTheCapFallsBackToOldestWhenEveryNameIsProtected() {
        var learned = LearnedNames()
        for i in 0..<LearnedNames.cap { learned.record("site\(i).com", at: t0.addingTimeInterval(Double(i))) }
        XCTAssertTrue(learned.record("extra.com", at: t0.addingTimeInterval(1e6), protected: learned.names))
        XCTAssertEqual(learned.count, LearnedNames.cap - LearnedNames.cap / 20 + 1)
        XCTAssertFalse(learned.names.contains("site0.com"), "nothing else to drop: the oldest goes")
        XCTAssertTrue(learned.names.contains("site\(LearnedNames.cap / 20).com"))
        XCTAssertTrue(learned.names.contains("extra.com"))
    }

    func testRecordAtTheCapDropsOnlyWhatIsUnprotectedWhenFewAre() {
        var learned = LearnedNames()
        for i in 0..<LearnedNames.cap { learned.record("site\(i).com", at: t0.addingTimeInterval(Double(i))) }
        let protected = learned.names.subtracting(["site7.com", "site1999.com"])
        XCTAssertTrue(learned.record("extra.com", at: t0.addingTimeInterval(1e6), protected: protected))
        XCTAssertFalse(learned.names.contains("site7.com"))
        XCTAssertFalse(learned.names.contains("site1999.com"))
        XCTAssertEqual(learned.count, LearnedNames.cap - 2 + 1, "protected names are not touched to make up the 5 %")
        XCTAssertTrue(learned.names.contains("site0.com"))
    }

    func testProtectedEvictionIsDeterministicOnTies() {
        func run() -> Set<String> {
            var l = LearnedNames(lastSeen: Dictionary(uniqueKeysWithValues:
                (0..<LearnedNames.cap).map { ("s\($0).com", t0) }))
            l.record("extra.com", at: t0, protected: Set((0..<1000).map { "s\($0).com" }))
            return l.names
        }
        XCTAssertEqual(run(), run())
        XCTAssertTrue(run().isSuperset(of: Set((0..<1000).map { "s\($0).com" })))
    }

    // MARK: Decoding (F6)

    func testDecodingDropsNamesThatAreNotHostnames() throws {
        let json = """
        {"lastSeen":{"mangadex.org":0,"manga.com\\n1.2.3.4 apple.com":0,"manga.com evil":1,"#manga.com":2,"a..b":3,"manga":4}}
        """
        let learned = try JSONDecoder().decode(LearnedNames.self, from: Data(json.utf8))
        XCTAssertEqual(learned.names, ["mangadex.org"])
    }
}
