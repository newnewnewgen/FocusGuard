import XCTest
@testable import FocusGuardCore

final class KeywordMatchTests: XCTestCase {
    func rule(_ match: KeywordRule.Match) -> KeywordRule { KeywordRule(text: "manga", match: match) }

    func testContains() {
        XCTAssertTrue(rule(.contains).matches(name: "mangadex.org"))
        XCTAssertTrue(rule(.contains).matches(name: "mangalore.in"))
        XCTAssertTrue(rule(.contains).matches(name: "yamanga.com"))
        XCTAssertFalse(rule(.contains).matches(name: "comics.org"))
    }

    func testWholeWord() {
        XCTAssertTrue(rule(.wholeWord).matches(name: "manga.example.com"))
        XCTAssertTrue(rule(.wholeWord).matches(name: "read-manga.net"))
        XCTAssertFalse(rule(.wholeWord).matches(name: "mangadex.org"))
        XCTAssertFalse(rule(.wholeWord).matches(name: "mangalore.in"))
    }

    func testStartsWith() {
        XCTAssertTrue(rule(.startsWith).matches(name: "mangadex.org"))
        XCTAssertTrue(rule(.startsWith).matches(name: "mangaplus.shueisha.co.jp"))
        XCTAssertTrue(rule(.startsWith).matches(name: "www.mangadex.org"), "www. is just another word")
        XCTAssertFalse(rule(.startsWith).matches(name: "yamanga.com"))
    }

    func testEndsWith() {
        XCTAssertTrue(rule(.endsWith).matches(name: "yamanga.com"))
        XCTAssertTrue(rule(.endsWith).matches(name: "read-manga.net"))
        XCTAssertFalse(rule(.endsWith).matches(name: "mangadex.org"))
    }

    func testCaseAndTrailingDot() {
        XCTAssertTrue(rule(.contains).matches(name: "MangaDex.ORG."))
    }

    func testKeywordBlocksUsesActiveWindowsAndAllowList() {
        let list = BlockList(name: "l", keywords: [rule(.contains)])
        let window = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        var config = Config(blockLists: [list], schedules: [window], alwaysAllow: ["mangalore.in"])
        let inside = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
        let outside = LocalMoment(weekday: .mon, minutesSinceMidnight: 800)
        XCTAssertTrue(config.keywordBlocks(name: "mangadex.org", at: inside))
        XCTAssertFalse(config.keywordBlocks(name: "mangadex.org", at: outside), "window not active")
        XCTAssertFalse(config.keywordBlocks(name: "mangalore.in", at: inside), "allowed")
        XCTAssertFalse(config.keywordBlocks(name: "www.mangalore.in", at: inside), "subdomain of an allowed name")
        config.alwaysAllow = ["https://MangaLore.in/"]
        XCTAssertFalse(config.keywordBlocks(name: "mangalore.in", at: inside), "allow entries are normalized")
    }

    func testAllKeywordRulesComesFromEnabledWindowsOnly() {
        let a = BlockList(name: "a", keywords: [rule(.contains)])
        let b = BlockList(name: "b", keywords: [KeywordRule(text: "anime", match: .contains)])
        let on = ScheduleWindow(name: "on", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [a.id])
        let off = ScheduleWindow(name: "off", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [b.id], enabled: false)
        let config = Config(blockLists: [a, b], schedules: [on, off])
        XCTAssertEqual(config.allKeywordRules.map(\.text), ["manga"])
        XCTAssertTrue(config.hasKeywordRules)
        XCTAssertFalse(Config(blockLists: [b], schedules: [off]).hasKeywordRules)
    }

    func testShouldLearnIgnoresAllowedAndNonMatching() {
        let list = BlockList(name: "l", keywords: [rule(.contains)])
        let window = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        let config = Config(blockLists: [list], schedules: [window], alwaysAllow: ["mangalore.in"])
        XCTAssertTrue(config.shouldLearn(name: "mangadex.org"), "learned even outside the window")
        XCTAssertFalse(config.shouldLearn(name: "mangalore.in"))
        XCTAssertFalse(config.shouldLearn(name: "comics.org"))
    }
}
