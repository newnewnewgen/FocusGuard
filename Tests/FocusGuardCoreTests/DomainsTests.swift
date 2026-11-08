import XCTest
@testable import FocusGuardCore

final class DomainsTests: XCTestCase {
    func testLowercasesAndTrims() {
        XCTAssertEqual(DomainNormalizer.normalize("  Reddit.COM "), "reddit.com")
    }

    func testStripsSchemePathAndPort() {
        XCTAssertEqual(DomainNormalizer.normalize("https://reddit.com/r/foo?x=1"), "reddit.com")
        XCTAssertEqual(DomainNormalizer.normalize("http://reddit.com:8080"), "reddit.com")
    }

    func testStripsLeadingWwwAndTrailingDot() {
        XCTAssertEqual(DomainNormalizer.normalize("www.reddit.com"), "reddit.com")
        XCTAssertEqual(DomainNormalizer.normalize("reddit.com."), "reddit.com")
    }

    func testKeepsOtherSubdomains() {
        XCTAssertEqual(DomainNormalizer.normalize("old.reddit.com"), "old.reddit.com")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(DomainNormalizer.normalize("   "), "")
        XCTAssertEqual(DomainNormalizer.normalize("https://"), "")
    }

    func testHostMatchesDomainOrSubdomain() {
        XCTAssertTrue(DomainNormalizer.host("old.reddit.com", isUnder: "reddit.com"))
        XCTAssertTrue(DomainNormalizer.host("reddit.com", isUnder: "reddit.com"))
        XCTAssertFalse(DomainNormalizer.host("notreddit.com", isUnder: "reddit.com"))
        XCTAssertFalse(DomainNormalizer.host("reddit.com.evil.io", isUnder: "reddit.com"))
    }

    func testRejectsNonHostnames() {
        XCTAssertEqual(DomainNormalizer.normalize("[::1]"), "")
        XCTAssertEqual(DomainNormalizer.normalize("http:/reddit.com"), "")
        XCTAssertEqual(DomainNormalizer.normalize("www."), "")
        XCTAssertEqual(DomainNormalizer.normalize("reddit .com"), "")
        XCTAssertEqual(DomainNormalizer.normalize("localhost"), "", "no dot → not a public hostname")
    }

    func testStripsUserinfoAndLeadingDots() {
        XCTAssertEqual(DomainNormalizer.normalize("user:pass@reddit.com"), "reddit.com")
        XCTAssertEqual(DomainNormalizer.normalize("https://user@reddit.com/"), "reddit.com")
        XCTAssertEqual(DomainNormalizer.normalize(".reddit.com"), "reddit.com")
    }

    func testIsHostname() {
        XCTAssertTrue(DomainNormalizer.isHostname("mangaplus.shueisha.co.jp"))
        XCTAssertTrue(DomainNormalizer.isHostname("a-b.c"))
        XCTAssertFalse(DomainNormalizer.isHostname("localhost"))
        XCTAssertFalse(DomainNormalizer.isHostname("a b.com"))
        XCTAssertFalse(DomainNormalizer.isHostname("a.com\n"))
        XCTAssertFalse(DomainNormalizer.isHostname(".a.com"))
        XCTAssertFalse(DomainNormalizer.isHostname("a..com"))
    }
}
