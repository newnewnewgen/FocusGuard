import XCTest
@testable import FocusGuardCore

final class BulkInputTests: XCTestCase {
    // MARK: Sites

    func testNewlineSeparatedSites() {
        let r = BulkInput.sites(from: "reddit.com\nyoutube.com\ntwitter.com\n")
        XCTAssertEqual(r.accepted, ["reddit.com", "youtube.com", "twitter.com"])
        XCTAssertEqual(r.rejected, [])
    }

    func testCommaSpaceAndSemicolonMix() {
        let r = BulkInput.sites(from: "reddit.com, youtube.com;twitter.com\tnews.ycombinator.com instagram.com")
        XCTAssertEqual(r.accepted, ["reddit.com", "youtube.com", "twitter.com", "news.ycombinator.com", "instagram.com"])
        XCTAssertEqual(r.rejected, [])
    }

    func testURLsWithPathsAndWWW() {
        let r = BulkInput.sites(from: "https://www.Reddit.com/r/all?x=1\nhttp://old.reddit.com/\nwww.youtube.com")
        XCTAssertEqual(r.accepted, ["reddit.com", "old.reddit.com", "youtube.com"])
        XCTAssertEqual(r.rejected, [])
    }

    func testHostsFileLines() {
        let text = """
        0.0.0.0 example.com
        127.0.0.1 a.com b.com
        ::1 x.org
        """
        let r = BulkInput.sites(from: text)
        XCTAssertEqual(r.accepted, ["example.com", "a.com", "b.com", "x.org"])
        XCTAssertEqual(r.rejected, [], "the address of a hosts line is neither a site nor a rejected token")
    }

    func testCommentLinesAndTrailingComments() {
        let text = """
        # my block list
        reddit.com # time sink
           # indented comment
        youtube.com
        """
        let r = BulkInput.sites(from: text)
        XCTAssertEqual(r.accepted, ["reddit.com", "youtube.com"])
        XCTAssertEqual(r.rejected, [])
    }

    func testDuplicatesCollapseKeepingFirstOccurrence() {
        let r = BulkInput.sites(from: "youtube.com\nreddit.com\nhttps://www.youtube.com/watch\nREDDIT.COM")
        XCTAssertEqual(r.accepted, ["youtube.com", "reddit.com"])
    }

    func testInvalidTokensAreRejectedOnceEach() {
        let r = BulkInput.sites(from: "reddit.com\nnot a site\nlocalhost\n[::1]\nlocalhost")
        XCTAssertEqual(r.accepted, ["reddit.com"])
        XCTAssertEqual(r.rejected, ["not", "a", "site", "localhost", "[::1]"], "every word of a sentence is a token; none has a dot")
    }

    func testSingleLetterTokenRejected() {
        let r = BulkInput.sites(from: "a reddit.com")
        XCTAssertEqual(r.accepted, ["reddit.com"])
        XCTAssertEqual(r.rejected, ["a"])
    }

    func testBareIPAddressesAreRejected() {
        let r = BulkInput.sites(from: "1.2.3.4\n0.0.0.0\n::1\nreddit.com")
        XCTAssertEqual(r.accepted, ["reddit.com"])
        XCTAssertEqual(r.rejected, ["1.2.3.4", "0.0.0.0", "::1"])
    }

    func testEmptyAndWhitespaceOnlyText() {
        XCTAssertEqual(BulkInput.sites(from: ""), BulkInput.Sites(accepted: [], rejected: []))
        XCTAssertEqual(BulkInput.sites(from: "  \n\t \n"), BulkInput.Sites(accepted: [], rejected: []))
        XCTAssertEqual(BulkInput.sites(from: "# only a comment\n"), BulkInput.Sites(accepted: [], rejected: []))
    }

    // MARK: Keywords

    func testKeywordsValidInvalidMixLowercasedAndDeduped() {
        let r = BulkInput.keywords(from: "Manga, anime\nx\nread-manga manga porn!\nANIME")
        XCTAssertEqual(r.accepted, ["manga", "anime", "read-manga"])
        XCTAssertEqual(r.rejected, ["x", "porn!"])
    }

    func testKeywordsNoHostsFileHandling() {
        // A hosts-style line is just tokens here: the address is not a keyword and lands in rejected.
        let r = BulkInput.keywords(from: "0.0.0.0 manga")
        XCTAssertEqual(r.accepted, ["manga"])
        XCTAssertEqual(r.rejected, ["0.0.0.0"])
    }

    func testKeywordsEmpty() {
        XCTAssertEqual(BulkInput.keywords(from: " \n "), BulkInput.Keywords(accepted: [], rejected: []))
    }
}
