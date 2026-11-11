import XCTest
@testable import FocusGuardCore

final class ChromeURLModelTests: XCTestCase {
    func testNormalizeTrimsAndKeepsCase() {
        XCTAssertEqual(ChromeURLPattern.normalize("  chrome://Extensions/* \n"), "chrome://Extensions/*")
        XCTAssertEqual(ChromeURLPattern.normalize("Example.com"), "Example.com", "kept verbatim; Chrome does its own matching")
    }

    func testEverySchemeIsAccepted() {
        for p in ["chrome://extensions/*", "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*",
                  "chrome-untrusted://x", "devtools://devtools/*", "file:///Users", "http://a.b", "https://a.b/c?d=e",
                  "CHROME://flags"] {
            XCTAssertTrue(ChromeURLPattern.isValid(p), p)
        }
    }

    func testBareHostPatterns() {
        for p in ["example.com", ".exact.host.com", "*", "example.com:8080/path", "1.2.3.4", "localhost"] {
            XCTAssertTrue(ChromeURLPattern.isValid(p), p)
        }
        for p in ["*.example.com", "-bad.com", "ex ample.com", "", "   ", "chrome://", "a\tb", "a\u{7}b", "..", ".", "/path"] {
            XCTAssertNil(ChromeURLPattern.normalize(p), "\u{201C}\(p)\u{201D} should be rejected")
        }
    }

    func testLengthLimit() {
        let long = "https://" + String(repeating: "a", count: ChromeURLPattern.maxLength - 8)
        XCTAssertTrue(ChromeURLPattern.isValid(long))
        XCTAssertNil(ChromeURLPattern.normalize(long + "a"))
    }

    func testOldConfigWithoutChromeURLsDecodes() throws {
        let json = """
        {"version":1,"blockLists":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"l","domains":["x.com"],"appBundleIDs":[],"keywords":[]}],"schedules":[]}
        """
        let config = try Config.decodeJSON(Data(json.utf8))
        XCTAssertEqual(config.blockLists[0].chromeURLs, [])
    }

    func testRoundTrip() throws {
        let config = Config(blockLists: [BlockList(name: "l", chromeURLs: ["chrome://extensions/*", "example.com"])])
        XCTAssertEqual(try Config.decodeJSON(try config.encodeJSON()), config)
    }

    func testInvalidPatternDoesNotDecode() throws {
        let config = Config(blockLists: [BlockList(name: "l", chromeURLs: ["chrome://extensions/*", "has space"])])
        XCTAssertThrowsError(try Config.decodeJSON(try config.encodeJSON())) { error in
            XCTAssertEqual(error as? Config.ValidationError, .invalidChromeURL("has space"))
        }
    }

    func testLimitAcrossLists() throws {
        var many = Config(blockLists: [BlockList(name: "a"), BlockList(name: "b")])
        many.blockLists[0].chromeURLs = (0..<Config.Limits.maxChromeURLs).map { "https://s\($0).test" }
        XCTAssertNoThrow(try Config.decodeJSON(try many.encodeJSON()))
        many.blockLists[1].chromeURLs = ["https://one.more"]
        XCTAssertThrowsError(try Config.decodeJSON(try many.encodeJSON()))
    }

    func testBulkInputChromeURLs() {
        let text = """
        chrome://extensions/*, chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*
        # comment
        example.com bad pattern *.nope.com
        chrome://extensions/*
        """
        let r = BulkInput.chromeURLs(from: text)
        XCTAssertEqual(r.accepted, ["chrome://extensions/*", "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*", "example.com", "bad", "pattern"])
        XCTAssertEqual(r.rejected, ["*.nope.com"])
        XCTAssertEqual(BulkInput.chromeURLs(from: " \n"), BulkInput.ChromeURLs(accepted: [], rejected: []))
    }
}
