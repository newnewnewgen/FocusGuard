import XCTest
@testable import FocusGuardCore

final class ChromeURLModelTests: XCTestCase {
    func testNormalizeTrimsAndKeepsCase() {
        XCTAssertEqual(ChromeURLPattern.normalize("  chrome://Extensions \n"), "chrome://Extensions")
        XCTAssertEqual(ChromeURLPattern.normalize("Example.com"), "Example.com", "kept verbatim; Chrome does its own matching")
    }

    /// Chrome matches the path as a literal prefix; `*` is not a wildcard there. 0.6.0 wrote
    /// `host/*`, which matched nothing (the live bug of 2026-11-12), so the form is stripped on
    /// normalize, stays valid in a stored config, and is stripped again on enforcement.
    func testTrailingPathWildcardIsStripped() {
        XCTAssertEqual(ChromeURLPattern.normalize("chrome://extensions"), "chrome://extensions")
        XCTAssertEqual(ChromeURLPattern.normalize("chrome-extension://abc/*"), "chrome-extension://abc")
        XCTAssertEqual(ChromeURLPattern.normalize("chrome://settings/privacy/*"), "chrome://settings/privacy")
        XCTAssertEqual(ChromeURLPattern.normalize("example.com/*"), "example.com")
        XCTAssertEqual(ChromeURLPattern.normalize("example.com:8080/*"), "example.com:8080")
        XCTAssertEqual(ChromeURLPattern.normalize("https://*"), "https://*", "every host of a scheme has no path")
        XCTAssertEqual(ChromeURLPattern.normalize("*"), "*")
        XCTAssertTrue(ChromeURLPattern.isValid("chrome://extensions"), "a 0.6.0 config stays readable")
        let config = Config(blockLists: [BlockList(name: "l", chromeURLs: ["chrome://extensions"])])
        XCTAssertNoThrow(try config.validate())
        XCTAssertEqual(config.items(ofLists: config.blockLists.map(\.id)).chromeURLs, ["chrome://extensions"])
    }

    func testEverySchemeIsAccepted() {
        for p in ["chrome://extensions", "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg",
                  "chrome-untrusted://x", "devtools://devtools", "file:///Users", "http://a.b", "https://a.b/c?d=e"] {
            XCTAssertTrue(ChromeURLPattern.isValid(p), p)
        }
    }

    func testSchemeIsLowercasedAndTheRestKept() {
        XCTAssertEqual(ChromeURLPattern.normalize("CHROME://flags"), "chrome://flags")
        XCTAssertEqual(ChromeURLPattern.normalize("Chrome-Extension://ABC/Path"), "chrome-extension://ABC/Path")
        XCTAssertEqual(ChromeURLPattern.normalize("HTTPS://Example.com/A?B=C"), "https://Example.com/A?B=C")
        XCTAssertTrue(ChromeURLPattern.isValid("CHROME://flags"), "normalizable, so valid in a stored config")
    }

    func testBareHostPortMustBeOneToFiveDigits() {
        for p in ["example.com:1", "example.com:65535", "example.com:8080/path", ".exact.com:443"] {
            XCTAssertTrue(ChromeURLPattern.isValid(p), p)
        }
        for p in ["example.com:", "example.com:abc", "example.com:123456", "example.com:80x", "example.com:/path",
                  "example.com:8080:1"] {
            XCTAssertNil(ChromeURLPattern.normalize(p), "\u{201C}\(p)\u{201D} should be rejected")
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
        let config = Config(blockLists: [BlockList(name: "l", chromeURLs: ["chrome://extensions", "example.com"])])
        XCTAssertEqual(try Config.decodeJSON(try config.encodeJSON()), config)
    }

    func testInvalidPatternDoesNotDecode() throws {
        let config = Config(blockLists: [BlockList(name: "l", chromeURLs: ["chrome://extensions", "has space"])])
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
        chrome://extensions, chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg
        # comment
        example.com bad pattern *.nope.com
        chrome://extensions
        """
        let r = BulkInput.chromeURLs(from: text)
        XCTAssertEqual(r.accepted, ["chrome://extensions", "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg", "example.com", "bad", "pattern"])
        XCTAssertEqual(r.rejected, ["*.nope.com"])
        XCTAssertEqual(BulkInput.chromeURLs(from: " \n"), BulkInput.ChromeURLs(accepted: [], rejected: []))
    }
}
