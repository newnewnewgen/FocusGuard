import XCTest
@testable import FocusGuardCore

final class HostsRegionTests: XCTestCase {
    let base = """
    ##
    # Host Database
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """

    func testRenderIsSortedAndCoversWwwAndIPv6() {
        let out = HostsRegion.render(domains: ["youtube.com", "reddit.com"])
        XCTAssertTrue(out.hasPrefix("""
        0.0.0.0 reddit.com
        0.0.0.0 www.reddit.com
        :: reddit.com
        :: www.reddit.com
        0.0.0.0 youtube.com
        0.0.0.0 www.youtube.com
        :: youtube.com
        :: www.youtube.com

        """), "got:\n\(out)")
    }

    func testRenderSinkholesDoHEndpointsAfterDomains() {
        let out = HostsRegion.render(domains: ["reddit.com"])
        XCTAssertTrue(out.contains("0.0.0.0 dns.google"))
        XCTAssertTrue(out.contains(":: mozilla.cloudflare-dns.com"))
        XCTAssertLessThan(out.range(of: "reddit.com")!.lowerBound, out.range(of: "dns.google")!.lowerBound)
    }

    func testRenderEmptyHasNoDoHLines() {
        XCTAssertEqual(HostsRegion.render(domains: []), "")
    }

    func testApplyAppendsRegionAndPreservesRest() {
        let out = HostsRegion.apply(domains: ["reddit.com"], to: base)
        XCTAssertTrue(out.hasPrefix(base + "# FOCUSGUARD START\n0.0.0.0 reddit.com\n"))
        XCTAssertTrue(out.hasSuffix("# FOCUSGUARD END\n"))
    }

    func testApplyReplacesExistingRegionInPlace() {
        let withOld = HostsRegion.apply(domains: ["old.com"], to: base)
        let out = HostsRegion.apply(domains: ["new.com"], to: withOld)
        XCTAssertFalse(out.contains("old.com"))
        XCTAssertTrue(out.contains("0.0.0.0 new.com"))
        XCTAssertEqual(out.components(separatedBy: HostsRegion.startMarker).count, 2, "exactly one region")
    }

    func testApplyIsIdempotent() {
        let once = HostsRegion.apply(domains: ["reddit.com"], to: base)
        XCTAssertEqual(HostsRegion.apply(domains: ["reddit.com"], to: once), once)
    }

    func testApplyEmptyRemovesRegionEntirely() {
        let withRegion = HostsRegion.apply(domains: ["reddit.com"], to: base)
        XCTAssertEqual(HostsRegion.apply(domains: [], to: withRegion), base)
        XCTAssertEqual(HostsRegion.apply(domains: [], to: base), base)
    }

    func testStripHandlesRegionInTheMiddle() {
        let contents = "a\n" + HostsRegion.startMarker + "\n0.0.0.0 x.com\n" + HostsRegion.endMarker + "\nb\n"
        XCTAssertEqual(HostsRegion.strip(contents), "a\nb\n")
    }

    func testStripToleratesMissingEndMarker() {
        let contents = "a\n" + HostsRegion.startMarker + "\n0.0.0.0 x.com\n"
        XCTAssertEqual(HostsRegion.strip(contents), "a\n")
    }

    func testApplyToFileWithoutTrailingNewline() {
        let out = HostsRegion.apply(domains: ["x.com"], to: "127.0.0.1 localhost")
        XCTAssertTrue(out.hasPrefix("127.0.0.1 localhost\n# FOCUSGUARD START\n"))
    }
}
