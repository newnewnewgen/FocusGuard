import XCTest
@testable import FocusGuardCore

final class KeywordModelTests: XCTestCase {
    func testNormalizeAcceptsSiteNameCharactersOnly() {
        XCTAssertEqual(KeywordRule.normalize("  Manga "), "manga")
        XCTAssertEqual(KeywordRule.normalize("READ-manga2"), "read-manga2")
        XCTAssertNil(KeywordRule.normalize("m"), "too short")
        XCTAssertNil(KeywordRule.normalize("manga.org"), "no dots: a keyword is one word")
        XCTAssertNil(KeywordRule.normalize("man ga"))
        XCTAssertNil(KeywordRule.normalize(String(repeating: "a", count: 64)))
    }

    func testItemKeyChangesWithTextOrMatch() {
        let a = KeywordRule(text: "manga", match: .contains)
        XCTAssertEqual(a.itemKey, "contains:manga")
        XCTAssertNotEqual(KeywordRule(text: "manga", match: .wholeWord).itemKey, a.itemKey)
    }

    func testOldConfigWithoutKeywordFieldsStillDecodes() throws {
        let json = """
        {"version":1,"blockLists":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"l","domains":["x.com"],"appBundleIDs":[]}],"schedules":[]}
        """
        let config = try Config.decodeJSON(Data(json.utf8))
        XCTAssertEqual(config.blockLists[0].keywords, [])
        XCTAssertEqual(config.alwaysAllow, [])
    }

    func testRoundTrip() throws {
        var config = Config(blockLists: [BlockList(name: "l", keywords: [KeywordRule(text: "manga", match: .startsWith)])])
        config.alwaysAllow = ["mangalore.in"]
        let decoded = try Config.decodeJSON(try config.encodeJSON())
        XCTAssertEqual(decoded, config)
    }

    func testInvalidKeywordTextDoesNotDecode() throws {
        let config = Config(blockLists: [BlockList(name: "l", keywords: [KeywordRule(text: "Manga Pages", match: .contains)])])
        XCTAssertThrowsError(try Config.decodeJSON(try config.encodeJSON()))
    }

    func testKeywordAndAllowLimits() throws {
        var many = Config(blockLists: [BlockList(name: "l")])
        many.blockLists[0].keywords = (0...Config.Limits.maxKeywords).map { KeywordRule(text: "k\($0)xx", match: .contains) }
        XCTAssertThrowsError(try Config.decodeJSON(try many.encodeJSON()))

        var allows = Config()
        allows.alwaysAllow = (0...Config.Limits.maxAllow).map { "a\($0).com" }
        XCTAssertThrowsError(try Config.decodeJSON(try allows.encodeJSON()))
    }
}
